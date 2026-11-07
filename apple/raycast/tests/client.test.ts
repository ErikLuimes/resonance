import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { createServer, type Server } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, beforeEach, test } from "node:test";
import { afterSkip, call, playTunes, search, status } from "../src/lib/client.ts";

// A stand-in for the app. Each test says how it answers.
const folder = mkdtempSync(join(tmpdir(), "resonance-raycast-"));
const socketPath = join(folder, "control.sock");
let server: Server;
let requests: { id: number; cmd: string; args: Record<string, unknown> }[] = [];
let answer: (request: { cmd: string }, count: number) => string | null = () => null;

before(async () => {
  process.env.RESONANCE_SOCKET = socketPath;
  process.env.RESONANCE_NO_LAUNCH = "1";
  server = createServer((socket) => {
    let pending = "";
    socket.on("data", (chunk) => {
      pending += chunk.toString();
      let newline: number;
      while ((newline = pending.indexOf("\n")) >= 0) {
        const request = JSON.parse(pending.slice(0, newline));
        pending = pending.slice(newline + 1);
        requests.push(request);
        const line = answer(request, requests.length);
        if (line === null) socket.end();
        else socket.write(line + "\n");
      }
    });
  });
  await new Promise<void>((resolve) => server.listen(socketPath, resolve));
});

beforeEach(() => {
  requests = [];
});

after(() => {
  server.close();
  rmSync(folder, { recursive: true, force: true });
});

const ok = (result: unknown) => JSON.stringify({ id: 1, ok: true, result });

test("sends the command and its arguments and returns the result", async () => {
  answer = () => ok([{ path: "/a.sid", title: "Commando", author: "Rob Hubbard", released: "1985" }]);
  const found = await search("commando", 5);
  assert.equal(found[0].title, "Commando");
  assert.equal(requests[0].cmd, "search");
  assert.deepEqual(requests[0].args, { text: "commando", limit: 5 });
});

test("leaves out what isn't given, so the app uses its defaults", async () => {
  answer = () => ok({});
  await playTunes(["/a.sid", "/b.sid"], "/b.sid");
  assert.deepEqual(requests[0].args, { paths: ["/a.sid", "/b.sid"], start: "/b.sid" });
});

test("reports the app's own words when it says no", async () => {
  answer = () => JSON.stringify({ id: 1, ok: false, error: "Nothing is playing." });
  await assert.rejects(call("fav"), /Nothing is playing\./);
});

test("reads an answer that arrives in pieces, split inside a character", async () => {
  const line = Buffer.from(ok({ state: "stopped", title: "Résumé" }) + "\n");
  server.removeAllListeners("connection");
  server.once("connection", (socket) => {
    socket.once("data", () => {
      const middle = line.indexOf(0xc3) + 1; // Inside the "é".
      socket.write(line.subarray(0, middle));
      setTimeout(() => socket.write(line.subarray(middle)), 20);
    });
  });
  const result = await call<{ title: string }>("status");
  assert.equal(result.title, "Résumé");
});

test("says so when the connection drops before an answer", async () => {
  server.removeAllListeners("connection");
  server.once("connection", (socket) => socket.once("data", () => socket.end()));
  await assert.rejects(status(), /Lost touch with Resonance/);
});

test("says the app isn't running when nothing listens", async () => {
  const before = process.env.RESONANCE_SOCKET;
  process.env.RESONANCE_SOCKET = join(folder, "nobody.sock");
  try {
    await assert.rejects(status(), /Resonance isn't running/);
  } finally {
    process.env.RESONANCE_SOCKET = before;
  }
});

test("afterSkip gives up on an unchanged tune", async () => {
  server.removeAllListeners("connection");
  let asked = 0;
  server.on("connection", (socket) => {
    socket.once("data", () => {
      asked += 1;
      socket.write(ok({ state: "playing", now: { path: "/same.sid" } }) + "\n");
    });
  });
  const result = await afterSkip("/same.sid", 2, 1);
  assert.equal(result.now?.path, "/same.sid");
  assert.equal(asked, 3);
  server.removeAllListeners("connection");
});

test("afterSkip stops as soon as the tune changes", async () => {
  let asked = 0;
  server.on("connection", (socket) => {
    socket.once("data", () => {
      asked += 1;
      const path = asked < 2 ? "/old.sid" : "/new.sid";
      socket.write(ok({ state: "playing", now: { path } }) + "\n");
    });
  });
  const result = await afterSkip("/old.sid", 10, 1);
  assert.equal(result.now?.path, "/new.sid");
  assert.equal(asked, 2);
  server.removeAllListeners("connection");
});
