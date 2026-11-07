import assert from "node:assert/strict";
import { test } from "node:test";
import { barcode, byline, clock, percent, spokenName, traitBars } from "../src/lib/format.ts";

test("barcode has nine bars, with an absent trait still marking its place", () => {
  assert.equal(barcode([1, 0, 0.5, 0, 0, 0, 0, 0.25, 0.75]), "█▁▄▁▁▁▁▂▆");
});

test("barcode keeps nine bars when traits are missing or out of range", () => {
  assert.equal(barcode([]), "▁▁▁▁▁▁▁▁▁");
  assert.equal(barcode([2, -1]), "█▁▁▁▁▁▁▁▁");
});

test("trait bars name each trait and line up", () => {
  const lines = traitBars([1, 0, 0.5]).split("\n");
  assert.equal(lines.length, 9);
  assert.ok(lines[0].startsWith("Notes"));
  assert.ok(lines[0].endsWith("█".repeat(16)));
  assert.ok(lines[1].endsWith("░".repeat(16)));
  assert.equal(new Set(lines.map((line) => line.length)).size, 1);
});

test("clock pads seconds and doesn't go negative", () => {
  assert.equal(clock(252.9), "4:12");
  assert.equal(clock(5), "0:05");
  assert.equal(clock(-3), "0:00");
});

test("percent rounds and stays in range", () => {
  assert.equal(percent(0.874), "87%");
  assert.equal(percent(1.2), "100%");
});

test("byline drops the by without a composer", () => {
  assert.equal(byline("Commando", "Hubbard, Rob"), "Commando by Rob Hubbard");
  assert.equal(byline("Commando", ""), "Commando");
});

test("spoken names put the first name first and leave others alone", () => {
  assert.equal(spokenName("Hubbard, Rob"), "Rob Hubbard");
  assert.equal(spokenName("Yip"), "Yip");
});
