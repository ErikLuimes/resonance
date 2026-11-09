import type { Status } from "./client";

export type Polled = { data?: Status; error?: Error; isLoading: boolean };

/** The tune a list's Play would act on differently: it's loaded, playing or paused. */
export type Playing = { path: string; state: "playing" | "paused" } | null;

export function playingFrom(status: Status | null): Playing {
  if (!status?.now || status.state === "stopped") return null;
  return { path: status.now.path, state: status.state };
}

/** Keeps `previous` itself when it's the same, so React doesn't render. */
export const samePlaying = (previous: Playing, next: Playing): Playing =>
  previous?.path === next?.path && previous?.state === next?.state ? previous : next;

/** The fields as shown: the clock shows whole seconds. */
const shown = (status: Status) => JSON.stringify({ ...status, elapsed: Math.floor(status.elapsed) });

/**
 * The state after a poll. It returns `previous` itself when nothing shown has changed, so
 * React doesn't render: Raycast warns about a loop after 20 renders in a row that change
 * nothing, which a poll every second reaches in seconds while paused.
 */
export function afterPoll(previous: Polled, result: { data: Status } | { error: Error }): Polled {
  if ("error" in result) {
    if (previous.error?.message === result.error.message) return previous;
    return { data: previous.data, error: result.error, isLoading: false };
  }
  if (previous.data && !previous.error && shown(previous.data) === shown(result.data)) return previous;
  return { data: result.data, isLoading: false };
}
