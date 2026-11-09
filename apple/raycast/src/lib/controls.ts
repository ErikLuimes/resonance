// With extensions so that the tests, which Node runs directly, can load this file.
import { afterSkip, call, status } from "./client.ts";
import { byline } from "./format.ts";

/** The playback controls. Each does its work and says what happened, for a HUD. */
export async function togglePlayback(): Promise<string> {
  await call("toggle");
  const current = await status();
  if (!current.now) return "Nothing to play";
  return current.state === "playing" ? `Playing ${current.now.title}` : `Paused ${current.now.title}`;
}

async function skip(cmd: string, nothing: string): Promise<string> {
  const before = await status();
  await call(cmd);
  const after = await afterSkip(before.now?.path);
  return after.now ? byline(after.now.title, after.now.author) : nothing;
}

export const nextTune = () => skip("next", "Nothing to play");
export const previousTune = () => skip("prev", "Nothing to play");
export const surpriseMe = () => skip("surprise", "Surprise on its way");
