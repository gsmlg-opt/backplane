import assert from "node:assert/strict";
import { createServer, type IncomingMessage } from "node:http";
import { readFile, writeFile } from "node:fs/promises";
import test from "node:test";

import { GoogleGenAI } from "@google/genai";

type Recording = {
  body: unknown;
  headers: Record<string, string | string[] | undefined>;
  method: string;
  path: string;
  query: string;
};

const model = "models/gemini-2.5-flash";
const apiKey = "backplane-sdk-contract-key";

const response = {
  candidates: [
    {
      content: { parts: [{ text: "recording response" }], role: "model" },
      finishReason: "STOP",
      index: 0
    }
  ],
  modelVersion: "gemini-2.5-flash",
  responseId: "recording-response-id",
  usageMetadata: { candidatesTokenCount: 2, promptTokenCount: 3, totalTokenCount: 5 }
};

async function readBody(request: IncomingMessage) {
  const chunks: Buffer[] = [];

  for await (const chunk of request) {
    chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
  }

  return Buffer.concat(chunks).toString("utf8");
}

test("@google/genai v2.24.0 emits the Gemini Developer API wire contract", async () => {
  const recordings: Recording[] = [];
  const server = createServer(async (request, serverResponse) => {
    const url = new URL(request.url ?? "/", "http://recording.invalid");
    const body = await readBody(request);

    recordings.push({
      body: body === "" ? null : JSON.parse(body),
      headers: request.headers,
      method: request.method ?? "",
      path: url.pathname,
      query: url.search
    });

    if (url.pathname.endsWith(":streamGenerateContent")) {
      serverResponse.writeHead(200, { "content-type": "text/event-stream" });
      serverResponse.write(`data: ${JSON.stringify(response)}\n\n`);
      serverResponse.end(`data: ${JSON.stringify({ ...response, usageMetadata: { candidatesTokenCount: 3, promptTokenCount: 3, totalTokenCount: 6 } })}\n\n`);
      return;
    }

    if (url.pathname.endsWith(":countTokens")) {
      serverResponse.writeHead(200, { "content-type": "application/json" });
      serverResponse.end(JSON.stringify({ totalTokens: 3 }));
      return;
    }

    if (request.method === "GET" && url.pathname.endsWith("/models")) {
      serverResponse.writeHead(200, { "content-type": "application/json" });
      serverResponse.end(JSON.stringify({ models: [{ displayName: "Gemini", name: model, supportedGenerationMethods: ["generateContent"] }] }));
      return;
    }

    if (request.method === "GET") {
      serverResponse.writeHead(200, { "content-type": "application/json" });
      serverResponse.end(JSON.stringify({ displayName: "Gemini", name: model, supportedGenerationMethods: ["generateContent"] }));
      return;
    }

    serverResponse.writeHead(200, { "content-type": "application/json" });
    serverResponse.end(JSON.stringify(response));
  });

  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));

  try {
    const address = server.address();
    assert.ok(address && typeof address !== "string");

    const ai = new GoogleGenAI({
      apiKey,
      httpOptions: { apiVersion: "v1beta", baseUrl: `http://127.0.0.1:${address.port}/deploy` }
    });

    const generated = await ai.models.generateContent({ contents: "sanitized generate prompt", model });
    assert.equal(generated.text, "recording response");

    const stream = await ai.models.generateContentStream({ contents: "sanitized stream prompt", model });
    const chunks = [];
    for await (const chunk of stream) chunks.push(chunk);
    assert.equal(chunks.length, 2);
    assert.equal(chunks[1].usageMetadata?.totalTokenCount, 6);

    const counted = await ai.models.countTokens({ contents: "sanitized count prompt", model });
    assert.equal(counted.totalTokens, 3);

    const models = [];
    for await (const listedModel of await ai.models.list()) models.push(listedModel);
    assert.equal(models[0]?.name, model);

    const fetched = await ai.models.get({ model });
    assert.equal(fetched.name, model);
  } finally {
    await new Promise<void>((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
  }

  assert.equal(recordings.length, 5);

  for (const recording of recordings) {
    assert.equal(recording.headers["x-goog-api-key"], apiKey);
    assert.match(recording.headers["x-goog-api-client"] as string, /^google-genai-sdk\/2\.24\.0 /);
    assert.equal(recording.query.includes("key="), false);
    assert.match(recording.path, /^\/deploy\/v1beta\/models(?:\/|$)/);
  }

  await writeFile(new URL("../fixtures/requests/typescript.captured.json", import.meta.url), JSON.stringify(recordings.map(({ body, method, path, query }) => ({ body, method, path, query })), null, 2) + "\n");

  const fixture = JSON.parse(await readFile(new URL("../fixtures/requests/typescript.json", import.meta.url), "utf8"));
  assert.deepEqual(recordings.map(({ body, method, path, query }) => ({ body, method, path, query })), fixture);
});
