import assert from "node:assert/strict";
import { test } from "node:test";
import type { Status } from "../src/lib/client.ts";
import { afterPoll, playingFrom, samePlaying, type Polled } from "../src/lib/poll.ts";

const paused: Status = { state: "paused", elapsed: 12.25, hasCollection: true, favorite: false };
const now = { path: "/a.sid", title: "Commando", author: "Rob Hubbard", released: "1985", song: 1, songs: 19 };

test("a list's playing tune is the one playing or paused", () => {
  assert.deepEqual(playingFrom({ ...paused, state: "playing", now }), { path: "/a.sid", state: "playing" });
  assert.deepEqual(playingFrom({ ...paused, now }), { path: "/a.sid", state: "paused" });
});

test("nothing counts as playing when stopped, with no tune, or with the app not running", () => {
  assert.equal(playingFrom({ ...paused, state: "stopped", now }), null);
  assert.equal(playingFrom(paused), null);
  assert.equal(playingFrom(null), null);
});

test("the playing tune keeps its state until the tune or the state changes", () => {
  const before = { path: "/a.sid", state: "playing" as const };
  assert.equal(samePlaying(before, { ...before }), before);
  assert.equal(samePlaying(null, null), null);
  const pausedNow = { path: "/a.sid", state: "paused" as const };
  assert.equal(samePlaying(before, pausedNow), pausedNow);
  const another = { path: "/b.sid", state: "playing" as const };
  assert.equal(samePlaying(before, another), another);
  assert.equal(samePlaying(before, null), null);
});

test("the first answer ends loading", () => {
  assert.deepEqual(afterPoll({ isLoading: true }, { data: paused }), { data: paused, isLoading: false });
});

test("the same answer keeps the same state, so nothing renders", () => {
  const before: Polled = { data: paused, isLoading: false };
  assert.equal(afterPoll(before, { data: { ...paused } }), before);
});

test("a fraction of a second keeps the same state, as the clock shows whole seconds", () => {
  const before: Polled = { data: paused, isLoading: false };
  assert.equal(afterPoll(before, { data: { ...paused, elapsed: 12.9 } }), before);
});

test("a new second, a new state or a favorite changes the state", () => {
  const before: Polled = { data: paused, isLoading: false };
  for (const change of [{ elapsed: 13 }, { state: "playing" as const }, { favorite: true }]) {
    const data = { ...paused, ...change };
    assert.deepEqual(afterPoll(before, { data }), { data, isLoading: false });
  }
});

test("an error keeps the tune, and the same error doesn't render again", () => {
  const after = afterPoll({ data: paused, isLoading: false }, { error: new Error("Gone") });
  assert.equal(after.data, paused);
  assert.equal(after.error?.message, "Gone");
  assert.equal(afterPoll(after, { error: new Error("Gone") }), after);
});

test("an answer after an error clears it, even if the status is the same", () => {
  const after = afterPoll({ data: paused, error: new Error("Gone"), isLoading: false }, { data: paused });
  assert.equal(after.error, undefined);
});
