// Words and characters for what the app answers with. A fingerprint is nine traits,
// always in the same order, so tunes that sound alike look alike; see
// apple/cli/src/fingerprint.rs for the terminal app's version.

const BLOCKS = [" ", "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"];
const MEANINGS = [
  "Notes",
  "Arpeggios",
  "Vibrato",
  "Filter",
  "Ring modulation",
  "Hard sync",
  "Digi samples",
  "Noise",
  "Pulse width",
];
const BAR_WIDTH = 16;

function level(traits: number[], index: number): number {
  return Math.min(Math.max(traits[index] ?? 0, 0), 1);
}

/** One row of nine, with what's absent still marking its place. */
export function barcode(traits: number[]): string {
  return MEANINGS.map((_, index) => BLOCKS[Math.max(Math.round(level(traits, index) * 8), 1)]).join("");
}

/** Each trait by name with a bar, for a monospaced block. */
export function traitBars(traits: number[]): string {
  const width = Math.max(...MEANINGS.map((name) => name.length));
  return MEANINGS.map((name, index) => {
    const filled = Math.round(level(traits, index) * BAR_WIDTH);
    return `${name.padEnd(width)}  ${"█".repeat(filled)}${"░".repeat(BAR_WIDTH - filled)}`;
  }).join("\n");
}

/** "4:12". */
export function clock(secs: number): string {
  const whole = Math.max(Math.floor(secs), 0);
  return `${Math.floor(whole / 60)}:${String(whole % 60).padStart(2, "0")}`;
}

/** "87%". */
export function percent(score: number): string {
  return `${Math.round(Math.min(Math.max(score, 0), 1) * 100)}%`;
}

/** "Rob Hubbard" for HVSC's "Hubbard, Rob"; the same as LibraryStore.spokenName. */
export function spokenName(name: string): string {
  const comma = name.indexOf(", ");
  return comma < 0 ? name : `${name.slice(comma + 2)} ${name.slice(0, comma)}`;
}

/** "Commando by Rob Hubbard", without the "by" when the composer isn't known. */
export function byline(title: string, author: string): string {
  return author ? `${title} by ${spokenName(author)}` : title;
}
