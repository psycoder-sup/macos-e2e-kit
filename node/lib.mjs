// Programmatic Node driver for the E2EBridge debug Unix-socket wire protocol.
//
// Wire: 4-byte BE length + JSON {op,args}  ->  4-byte BE length + JSON {ok, result|error}.
// One connection per call — the server serves exactly one request/response per connection,
// so every call() opens a fresh socket, writes a single frame, and reads a single frame back.
//
// Socket path is not guessed here (app-specific bundle ID / instance suffixes live in the host
// app or harness) — pass { sock } explicitly or set SOCK / E2E_SOCK.
import net from "node:net";
import fs from "node:fs";
import { join } from "node:path";
import { isDeepStrictEqual } from "node:util";

// Thrown when a call returns a well-formed {ok:false, error:{code,message}} envelope.
export class E2EError extends Error {
  constructor(code, message) {
    super(message);
    this.name = "E2EError";
    this.code = code;
  }
}

// Thrown by expect() assertions.
export class ExpectError extends Error {
  constructor(message) {
    super(message);
    this.name = "ExpectError";
  }
}

function fmt(v) {
  try {
    return JSON.stringify(v);
  } catch {
    return String(v);
  }
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// Single request/response over a fresh connection. Resolves with the raw {ok,...} envelope
// (or rejects on transport-level failure — timeout, connection error, premature close, bad JSON).
function wireCall(sock, op, args, timeoutMs) {
  return new Promise((resolve, reject) => {
    let received = Buffer.alloc(0);
    let expected = null;
    let settled = false;
    const socket = net.createConnection(sock);
    const finish = (fn) => {
      if (settled) return;
      settled = true;
      socket.destroy();
      fn();
    };
    socket.setTimeout(timeoutMs, () => finish(() => reject(new Error("IPC timeout"))));
    socket.on("connect", () => {
      const payload = Buffer.from(JSON.stringify({ op, args }), "utf8");
      const header = Buffer.alloc(4);
      header.writeUInt32BE(payload.byteLength, 0);
      socket.write(header);
      socket.write(payload);
    });
    socket.on("data", (chunk) => {
      received = Buffer.concat([received, chunk]);
      if (expected === null && received.byteLength >= 4) expected = received.readUInt32BE(0);
      if (expected !== null && received.byteLength >= 4 + expected) {
        const body = received.subarray(4, 4 + expected).toString("utf8");
        try {
          finish(() => resolve(JSON.parse(body)));
        } catch (e) {
          finish(() => reject(new Error("parse failed: " + e)));
        }
      }
    });
    socket.on("error", (e) => finish(() => reject(e)));
    socket.on("end", () => {
      if (!settled) {
        finish(() => reject(new Error("connection closed before response (server not running / peer verify)")));
      }
    });
  });
}

// Flatten an AX tree to compact lines for identified / interactive / text nodes.
const INTERESTING_ROLES = [
  "AXButton",
  "AXTextField",
  "AXTextArea",
  "AXPopUpButton",
  "AXMenuButton",
  "AXCheckBox",
  "AXStaticText",
];

function flattenNode(node, depth, out) {
  const interesting = Boolean(node.identifier) || INTERESTING_ROLES.includes(node.role);
  if (interesting) {
    const f = node.frame || {};
    out.push(
      `${"  ".repeat(depth)}${node.role}${node.identifier ? " #" + node.identifier : ""}` +
        `${node.label ? " label=" + JSON.stringify(node.label) : ""}` +
        `${node.value != null ? " value=" + JSON.stringify(String(node.value).slice(0, 40)) : ""}` +
        `${node.focused ? " [focused]" : ""}${node.enabled === false ? " [disabled]" : ""}` +
        ` @(${Math.round(f.x ?? 0)},${Math.round(f.y ?? 0)} ${Math.round(f.width ?? 0)}x${Math.round(f.height ?? 0)})`
    );
  }
  for (const c of node.children || []) flattenNode(c, depth + (interesting ? 1 : 0), out);
}

// Find the first node matching an identifier string or predicate function, walking children
// depth-first across all windows.
function findNode(windows, idOrPredicate) {
  const matches =
    typeof idOrPredicate === "function"
      ? idOrPredicate
      : (node) => node.identifier === idOrPredicate;
  function walk(node) {
    if (matches(node)) return node;
    for (const c of node.children || []) {
      const found = walk(c);
      if (found) return found;
    }
    return undefined;
  }
  for (const w of windows || []) {
    const found = walk(w);
    if (found) return found;
  }
  return undefined;
}

export function client({ sock, timeoutMs = 20000 } = {}) {
  const resolvedSock = sock ?? process.env.SOCK ?? process.env.E2E_SOCK;
  if (!resolvedSock) {
    throw new Error("client(): no socket path — pass { sock } or set SOCK / E2E_SOCK env var");
  }

  async function call(op, args = {}, callTimeoutMs) {
    const envelope = await wireCall(resolvedSock, op, args, callTimeoutMs ?? timeoutMs);
    if (envelope && envelope.ok === true) return envelope.result;
    const error = (envelope && envelope.error) || {};
    throw new E2EError(error.code || "protocol_error", error.message || `call "${op}" failed`);
  }

  async function ping() {
    return call("debug.ping");
  }

  async function tree() {
    const result = await call("debug.ui_tree");
    return result.windows || [];
  }

  // windows optional — omit to fetch a fresh tree first.
  async function flat(windows) {
    const list = windows ?? (await tree());
    const out = [];
    for (const w of list) flattenNode(w, 0, out);
    return out.join("\n");
  }

  function find(windows, idOrPredicate) {
    return findNode(windows, idOrPredicate);
  }

  async function shot(prefix, dir = ".") {
    const result = await call("debug.screenshot");
    const saved = [];
    (result.windows || []).forEach((w, i) => {
      const ext = w.contentType === "image/jpeg" ? "jpg" : "png";
      const safeTitle = (w.title || "win").replace(/[^\w.-]+/g, "_");
      const path = join(dir, `${prefix}-${i}-${safeTitle}.${ext}`);
      fs.writeFileSync(path, Buffer.from(w.dataBase64, "base64"));
      saved.push(path);
    });
    return saved;
  }

  async function perform(id) {
    return call("debug.ui_perform", { identifier: id });
  }

  async function setval(id, value) {
    return call("debug.ui_set_value", { identifier: id, value });
  }

  async function type(text, id) {
    return call("debug.type", id ? { text, identifier: id } : { text });
  }

  async function key(name, mods = []) {
    return call("debug.key", mods.length ? { key: name, modifiers: mods } : { key: name });
  }

  async function waitFor(fn, { timeoutMs: waitTimeoutMs = 10000, intervalMs = 250, desc } = {}) {
    const deadline = Date.now() + waitTimeoutMs;
    for (;;) {
      const result = await fn();
      if (result) return result;
      if (Date.now() >= deadline) {
        throw new Error(`waitFor timed out after ${waitTimeoutMs}ms${desc ? `: ${desc}` : ""}`);
      }
      await sleep(intervalMs);
    }
  }

  async function waitForNode(id, { enabled, timeoutMs: waitTimeoutMs } = {}) {
    return waitFor(
      async () => {
        const windows = await tree();
        const node = findNode(windows, id);
        if (!node) return undefined;
        if (enabled === true && node.enabled === false) return undefined;
        return node;
      },
      { timeoutMs: waitTimeoutMs, desc: `node "${id}"${enabled === true ? " enabled" : ""}` }
    );
  }

  return {
    call,
    ping,
    tree,
    flat,
    find,
    shot,
    perform,
    setval,
    type,
    key,
    waitFor,
    waitForNode,
  };
}

export function expect(actual) {
  return {
    toBe(expected) {
      if (!Object.is(actual, expected)) {
        throw new ExpectError(`expected ${fmt(actual)} to be ${fmt(expected)}`);
      }
    },
    toEqual(expected) {
      if (!isDeepStrictEqual(actual, expected)) {
        throw new ExpectError(`expected ${fmt(actual)} to equal ${fmt(expected)}`);
      }
    },
    toContain(expected) {
      const contains =
        typeof actual === "string" || Array.isArray(actual) ? actual.includes(expected) : false;
      if (!contains) {
        throw new ExpectError(`expected ${fmt(actual)} to contain ${fmt(expected)}`);
      }
    },
    toMatch(re) {
      const pattern = re instanceof RegExp ? re : new RegExp(re);
      if (!pattern.test(String(actual))) {
        throw new ExpectError(`expected ${fmt(actual)} to match ${pattern}`);
      }
    },
    toBeTruthy() {
      if (!actual) {
        throw new ExpectError(`expected ${fmt(actual)} to be truthy`);
      }
    },
  };
}

expect.node = function (windows, id) {
  const node = findNode(windows, id);
  if (!node) throw new ExpectError(`expected node "${id}" to exist`);
  return node;
};

expect.enabled = function (windows, id) {
  const node = expect.node(windows, id);
  if (node.enabled === false) throw new ExpectError(`expected node "${id}" to be enabled`);
  return node;
};

expect.disabled = function (windows, id) {
  const node = expect.node(windows, id);
  if (node.enabled !== false) throw new ExpectError(`expected node "${id}" to be disabled`);
  return node;
};

expect.value = function (windows, id, v) {
  const node = expect.node(windows, id);
  if (node.value !== v) {
    throw new ExpectError(`expected node "${id}" value ${fmt(node.value)} to be ${fmt(v)}`);
  }
  return node;
};
