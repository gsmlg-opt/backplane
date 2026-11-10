/** OpenClaw v2026.10.10 public SDK adapter. Memory lives in Backplane, reached through the local host agent. */
import { TOOL_NAMES } from "./contract.mjs";
import { configSchema, createMemoryService } from "./service.mjs";
export { createPlaintextWarner } from "./client.mjs";
export { createMemoryService, configSchema } from "./service.mjs";

export default {
  id: "backplane-memory", name: "backplane-memory",
  description: "Backplane memory shared across the user's agents and hosts.", configSchema,
  register(api) {
    if (api.pluginConfig?.enabled === false) return;
    const service = createMemoryService(api);
    api.registerTool({ contextVersion: 2, create: (ctx) => service.tools(ctx) }, { names: Object.values(TOOL_NAMES) });
    api.registerMemoryCapability({
      recallToolNames: [TOOL_NAMES.search, TOOL_NAMES.get],
      providerRuntime: {
        open: (params) => service.open(params),
        closeAllMemorySearchManagers: () => service.closeSearchLeases(),
      },
      providerFlushPlanResolver: () => service.flushPlan(),
      promptBuilder: () => service.promptLines(),
    });
    if (service.conversationAccess) {
      api.on("before_prompt_build", (event, ctx) => service.beforePrompt(event, ctx), { requiresToolAuthority: true });
      api.on("agent_end", (event, ctx) => service.agentEnd(event, ctx));
      api.on("session_end", (event, ctx) => service.sessionEnd(event, ctx));
    } else api.logger?.warn?.("backplane-memory: conversation_access_required; set plugins.entries.backplane-memory.hooks.allowConversationAccess=true to enable automatic context and capture");
    api.registerService({ id: "backplane-memory-delivery", start: () => service.start(), stop: () => service.stop() });
    api.lifecycle?.onDispose?.(() => service.stop());
  },
};
