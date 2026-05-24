/**
 * Backplane Memory plugin for OpenClaw.
 *
 * Speaks to the local Backplane host agent's Memory HTTP API
 * (default http://127.0.0.1:4221/memory/<agent_id>/...), which proxies
 * everything through the host agent's authenticated WebSocket channel
 * to the Backplane hub.
 *
 * Integration points:
 *   - registerMemoryCapability({ promptBuilder }) — claims the
 *     plugins.slots.memory slot
 *   - before_agent_start — recall + inject relevant prior memories
 *   - agent_end — capture the completed conversation turn
 */

const DEFAULT_BASE_URL = "http://127.0.0.1:4221";
const DEFAULT_AGENT_ID = "openclaw";
const DEFAULT_TIMEOUT_MS = 5000;
const LOOPBACK_HOSTS = new Set(["localhost", "127.0.0.1", "::1"]);

const configSchema = {
  type: "object",
  additionalProperties: false,
  properties: {
    enabled: { type: "boolean" },
    base_url: { type: "string" },
    agent_id: { type: "string" },
    token_budget: { type: "number" },
    min_confidence: { type: "number" },
    fallback_on_error: { type: "boolean" },
    timeout_ms: { type: "number" },
  },
};

function normalizedHostname(hostname) {
  return hostname.replace(/^\[|\]$/g, "").toLowerCase();
}

function isPlaintextRemote(baseUrl) {
  try {
    const parsed = new URL(baseUrl);
    return (
      parsed.protocol === "http:" &&
      !LOOPBACK_HOSTS.has(normalizedHostname(parsed.hostname))
    );
  } catch {
    return false;
  }
}

export function createPlaintextWarner(warn) {
  let warned = false;
  return function maybeWarn(baseUrl) {
    if (warned) return;
    if (!isPlaintextRemote(baseUrl)) return;
    warned = true;
    warn(
      `backplane-memory: sending requests in plaintext to non-loopback host ${baseUrl}. ` +
        "Tunnel over SSH or set base_url to an https:// URL."
    );
  };
}

function extractText(content) {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .flatMap((block) => {
      if (!block || typeof block !== "object") return [];
      if (block.type === "text" && typeof block.text === "string") return [block.text];
      return [];
    })
    .join("\n")
    .trim();
}

function lastAssistantText(messages) {
  for (const message of [...messages].reverse()) {
    if (!message || typeof message !== "object") continue;
    if (message.role !== "assistant") continue;
    const text = extractText(message.content);
    if (text) return text;
  }
  return "";
}

function latestUserText(messages) {
  for (const message of [...messages].reverse()) {
    if (!message || typeof message !== "object") continue;
    if (message.role !== "user") continue;
    const text = extractText(message.content);
    if (text) return text;
  }
  return "";
}

function formatRecallResults(rows) {
  if (!Array.isArray(rows) || rows.length === 0) return "";
  return rows
    .slice(0, 5)
    .map((row, index) => {
      const content = (row?.content ?? "").trim();
      const scope = (row?.scope ?? "").trim();
      const title = `Memory ${index + 1}${scope ? ` (${scope})` : ""}`;
      return content ? `- ${title}: ${content.slice(0, 280)}` : null;
    })
    .filter(Boolean)
    .join("\n");
}

function unwrap(body) {
  if (!body || body.ok === false) return null;
  return body.result ?? null;
}

function createClient(cfg, api) {
  const baseUrl = String(cfg.base_url || DEFAULT_BASE_URL).replace(/\/+$/, "");
  const agentId = encodeURIComponent(cfg.agent_id || DEFAULT_AGENT_ID);
  const timeoutMs = Number(cfg.timeout_ms || DEFAULT_TIMEOUT_MS);
  const fallbackOnError = cfg.fallback_on_error !== false;
  const warnPlaintext = createPlaintextWarner(
    (message) => api.logger?.warn?.(message) ?? console.warn(message)
  );

  async function call(method, args) {
    warnPlaintext(baseUrl);
    const url = `${baseUrl}/memory/${agentId}/call/${encodeURIComponent(method)}`;
    try {
      const res = await fetch(url, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(args || {}),
        signal: AbortSignal.timeout(timeoutMs),
      });
      if (!res.ok) {
        if (fallbackOnError) return null;
        const text = await res.text().catch(() => "");
        throw new Error(`backplane-memory ${method} failed: ${res.status} ${text}`);
      }
      const body = await res.json();
      return unwrap(body);
    } catch (error) {
      if (!fallbackOnError) throw error;
      api.logger?.warn?.(`backplane-memory: ${String(error)}`);
      return null;
    }
  }

  return { call, baseUrl };
}

const plugin = {
  id: "backplane-memory",
  name: "backplane-memory",
  description: "Cross-session memory via the local Backplane host agent.",
  configSchema,
  register(api) {
    const cfg = {
      enabled: api.pluginConfig?.enabled !== false,
      base_url: api.pluginConfig?.base_url || DEFAULT_BASE_URL,
      agent_id: api.pluginConfig?.agent_id || DEFAULT_AGENT_ID,
      token_budget: api.pluginConfig?.token_budget || 2000,
      min_confidence: api.pluginConfig?.min_confidence || 0.5,
      fallback_on_error: api.pluginConfig?.fallback_on_error !== false,
      timeout_ms: api.pluginConfig?.timeout_ms || DEFAULT_TIMEOUT_MS,
    };
    const client = createClient(cfg, api);

    if (typeof api.registerMemoryCapability === "function") {
      api.registerMemoryCapability({
        promptBuilder: (_params) => [
          `Long-term memory provider: backplane-memory (Backplane host agent at ${client.baseUrl}).`,
          "Relevant prior observations are recalled before each turn via before_agent_start and captured via agent_end.",
          "Treat recalled context as background, not authoritative — prefer current workspace state and explicit user instructions when they conflict.",
        ],
      });
    }

    api.on("before_agent_start", async (event) => {
      if (!cfg.enabled) return;
      const prompt = typeof event?.prompt === "string" ? event.prompt.trim() : "";
      if (!prompt) return;
      const result = await client.call("recall", {
        query: prompt,
        limit: 5,
      });
      const block = formatRecallResults(result?.results || []);
      if (!block) return;
      return {
        prependContext: `Relevant long-term memory from backplane:\n${block}`,
      };
    });

    api.on("agent_end", async (event) => {
      if (!cfg.enabled || !event?.success || !Array.isArray(event.messages)) return;
      const userText = latestUserText(event.messages);
      const assistantText = lastAssistantText(event.messages);
      if (!userText || !assistantText) return;
      const sessionId =
        event.sessionId ||
        event.sessionKey ||
        event.runId ||
        `openclaw-${Date.now()}`;

      const content =
        `User: ${userText.slice(0, 1000).trim()}\n\n` +
        `Assistant: ${assistantText.slice(0, 4000).trim()}`;

      await client.call("remember", {
        content,
        type: "episodic",
        session_id: sessionId,
        metadata: {
          captured_at: new Date().toISOString(),
          source: "openclaw.agent_end",
        },
      });
    });
  },
};

export default plugin;
