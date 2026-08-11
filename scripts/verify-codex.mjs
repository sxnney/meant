#!/usr/bin/env node

import { spawn } from "node:child_process";
import { access } from "node:fs/promises";
import { constants } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import readline from "node:readline";

const candidates = [
  join(homedir(), ".local/bin/codex"),
  join(homedir(), ".codex/packages/standalone/current/bin/codex"),
  "/Applications/ChatGPT.app/Contents/Resources/codex",
  "/opt/homebrew/bin/codex",
  "/usr/local/bin/codex",
];

let executable;
for (const candidate of candidates) {
  try {
    await access(candidate, constants.X_OK);
    executable = candidate;
    break;
  } catch {}
}
if (!executable) throw new Error("Codex executable not found");

const child = spawn(executable, ["app-server", "--stdio"], {
  stdio: ["pipe", "pipe", "pipe"],
});
const lines = readline.createInterface({ input: child.stdout });
let nextID = 1;
const pending = new Map();
const notifications = [];
let stderr = "";
child.stderr.on("data", (data) => { stderr += data.toString(); });

function send(message) {
  child.stdin.write(`${JSON.stringify(message)}\n`);
}

function request(method, params = {}, timeout = 30_000) {
  const id = nextID++;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      pending.delete(id);
      reject(new Error(`${method} timed out`));
    }, timeout);
    pending.set(id, { method, resolve, reject, timer });
    send({ method, id, params });
  });
}

lines.on("line", (line) => {
  const message = JSON.parse(line);
  if (message.id != null && !message.method) {
    const item = pending.get(Number(message.id));
    if (!item) return;
    clearTimeout(item.timer);
    pending.delete(Number(message.id));
    message.error ? item.reject(new Error(message.error.message)) : item.resolve(message.result ?? {});
    return;
  }
  notifications.push(message);
});

function waitFor(method, predicate = () => true, timeout = 90_000) {
  return new Promise((resolve, reject) => {
    const started = Date.now();
    const interval = setInterval(() => {
      const index = notifications.findIndex(
        (message) => message.method === method && predicate(message.params ?? {}),
      );
      if (index >= 0) {
        const [message] = notifications.splice(index, 1);
        clearInterval(interval);
        resolve(message.params);
      } else if (Date.now() - started > timeout) {
        clearInterval(interval);
        reject(new Error(`${method} notification timed out`));
      }
    }, 10);
  });
}

try {
  await request("initialize", {
    clientInfo: { name: "meant_protocol_probe", title: "Meant protocol probe", version: "1.0.0" },
  });
  send({ method: "initialized", params: {} });

  const accountResult = await request("account/read", { refreshToken: false });
  if (accountResult.account?.type !== "chatgpt") {
    throw new Error(`Expected ChatGPT subscription auth, got ${accountResult.account?.type ?? "signed out"}`);
  }

  const modelResult = await request("model/list", { limit: 100, includeHidden: false });
  const model = modelResult.data.find((item) => item.id === "gpt-5.6-sol")
    ?? modelResult.data.find((item) => item.id.startsWith("gpt-5.6"));
  if (!model) throw new Error("No GPT-5.6 model is available");
  const efforts = model.supportedReasoningEfforts.map((item) => item.reasoningEffort);
  const fastEffort = efforts.includes("low") ? "low" : model.defaultReasoningEffort;
  const balancedEffort = efforts.includes("medium") ? "medium" : model.defaultReasoningEffort;

  const analysisStartedAt = Date.now();
  const threadResult = await request("thread/start", {
    model: model.id,
    cwd: join(homedir(), "Library/Application Support/Meant/Session"),
    approvalPolicy: "never",
    sandbox: "read-only",
    ephemeral: true,
    serviceName: "meant_protocol_probe",
    baseInstructions: `Infer one to three context-specific rewrite actions for selected text. If one intent is dominant, return one action. Titles must be specific verb phrases. Return only strict JSON in this shape: {"actions":[{"title":"Make implementation-ready","instruction":"Rewrite this as an executable implementation request with explicit constraints.","presentation":"preview"}]}. Presentation must be "replace" or "preview". Do not use tools.`,
  });
  const threadID = threadResult.thread.id;
  const turnResult = await request("turn/start", {
    threadId: threadID,
    input: [{ type: "text", text: "hey can you fix the codex integration because sometimes it hangs after streaming and make sure cancellation really stops it but do not rewrite the architecture and keep the existing subscription login" }],
    model: model.id,
    effort: fastEffort,
    summary: "none",
    sandboxPolicy: { type: "readOnly", networkAccess: false },
  });
  const turnID = turnResult.turn.id;
  const completed = await waitFor("turn/completed", (params) => params.threadId === threadID);
  const deltas = notifications
    .filter((message) => message.method === "item/agentMessage/delta" && message.params.threadId === threadID)
    .map((message) => message.params.delta)
    .join("");
  const finalText = completed.turn.items.findLast((item) => item.type === "agentMessage")?.text ?? deltas;
  if (completed.turn.status !== "completed" || !finalText.trim()) {
    throw new Error(`Action inference failed with status ${completed.turn.status}`);
  }
  const envelope = JSON.parse(finalText.slice(finalText.indexOf("{"), finalText.lastIndexOf("}") + 1));
  if (!Array.isArray(envelope.actions) || envelope.actions.length < 1 || envelope.actions.length > 3) {
    throw new Error("Action inference did not return one to three actions");
  }
  const action = envelope.actions[0];
  if (!action.title || !action.instruction || !["replace", "preview"].includes(action.presentation)) {
    throw new Error("Action inference returned an invalid action");
  }

  const transformStartedAt = Date.now();
  const transformThreadResult = await request("thread/start", {
    model: model.id,
    cwd: join(homedir(), "Library/Application Support/Meant/Session"),
    approvalPolicy: "never",
    sandbox: "read-only",
    ephemeral: true,
    serviceName: "meant_protocol_probe",
    baseInstructions: `Transform selected text according to this action: ${action.instruction}\nPreserve facts, constraints, technical strings, personality, and deliberate emphasis. Remove filler and repetition. Return only the transformed text. Do not answer the request or use tools.`,
  });
  const transformThreadID = transformThreadResult.thread.id;
  const transformTurnResult = await request("turn/start", {
    threadId: transformThreadID,
    input: [{ type: "text", text: "hey can you fix the codex integration because sometimes it hangs after streaming and make sure cancellation really stops it but do not rewrite the architecture and keep the existing subscription login" }],
    model: model.id,
    effort: balancedEffort,
    summary: "none",
    sandboxPolicy: { type: "readOnly", networkAccess: false },
  });
  const transformCompleted = await waitFor(
    "turn/completed",
    (params) => params.threadId === transformThreadID,
  );
  const transformDeltas = notifications
    .filter((message) => message.method === "item/agentMessage/delta" && message.params.threadId === transformThreadID)
    .map((message) => message.params.delta)
    .join("");
  const transformedText = transformCompleted.turn.items.findLast((item) => item.type === "agentMessage")?.text
    ?? transformDeltas;
  if (transformCompleted.turn.status !== "completed" || !transformedText.trim()) {
    throw new Error(`Transformation failed with status ${transformCompleted.turn.status}`);
  }

  const cancelThreadResult = await request("thread/start", {
    model: model.id,
    cwd: join(homedir(), "Library/Application Support/Meant/Session"),
    approvalPolicy: "never",
    sandbox: "read-only",
    ephemeral: true,
    baseInstructions: "Rewrite the input in exhaustive detail. Return only the rewrite. Do not use tools.",
  });
  const cancelThreadID = cancelThreadResult.thread.id;
  const cancelInput = Array.from(
    { length: 180 },
    (_, index) => `Requirement ${index + 1}: preserve this distinct implementation constraint and explain its verification path.`,
  ).join("\n");
  const cancelTurnPromise = request("turn/start", {
    threadId: cancelThreadID,
    input: [{ type: "text", text: cancelInput }],
    model: model.id,
    effort: efforts.includes("high") ? "high" : balancedEffort,
    summary: "none",
    sandboxPolicy: { type: "readOnly", networkAccess: false },
  });
  const started = await waitFor("turn/started", (params) => params.threadId === cancelThreadID);
  await request("turn/interrupt", {
    threadId: cancelThreadID,
    turnId: started.turn.id,
  });
  await cancelTurnPromise;
  const interrupted = await waitFor("turn/completed", (params) => params.threadId === cancelThreadID);
  if (!["interrupted", "completed"].includes(interrupted.turn.status)) {
    throw new Error(`Cancellation ended with unexpected status ${interrupted.turn.status}`);
  }

  console.log(JSON.stringify({
    executable,
    auth: accountResult.account.type,
    plan: accountResult.account.planType,
    model: model.id,
    efforts: { analysis: fastEffort, transformation: balancedEffort },
    inference: {
      status: completed.turn.status,
      turnID,
      milliseconds: transformStartedAt - analysisStartedAt,
      actions: envelope.actions,
    },
    transformation: {
      status: transformCompleted.turn.status,
      turnID: transformTurnResult.turn.id,
      milliseconds: Date.now() - transformStartedAt,
      characters: transformedText.length,
      sample: transformedText,
    },
    cancellation: interrupted.turn.status,
  }, null, 2));
} finally {
  lines.close();
  child.kill("SIGTERM");
  if (stderr.trim()) process.stderr.write(stderr);
}
