// The connection to the running app: one JSON object per line each way, over the
// socket described in apple/cli/README.md. The same protocol as apple/cli/src/client.rs;
// the commands are in Resonance/Services/ControlCommands.swift. If the app isn't
// running, it starts in the background, as it does for the command line tool.

import { execFile } from "node:child_process";
import { connect, type Socket } from "node:net";
import { homedir } from "node:os";
import { join } from "node:path";

export type Tune = {
  path: string;
  title: string;
  author: string;
  released: string;
  songs?: number;
  secs?: number | null;
  /** How alike, 0–1, in Sounds Like. */
  score?: number | null;
  /** When it last played, in seconds since 1970, in Recently Played. */
  playedAt?: number | null;
};

export type Status = {
  state: "playing" | "paused" | "stopped";
  now?: { path: string; title: string; author: string; released: string; song: number; songs: number } | null;
  elapsed: number;
  duration?: number | null;
  hasCollection: boolean;
  favourite: boolean;
  source?: string | null;
};

export type PlaylistInfo = { name: string; count: number; isFavourites: boolean };
export type Described = { title: string; note?: string | null; tunes: Tune[] };
export type Sound = { summary: string; tags: string[] };
export type Print = { path: string; traits: number[] };

const BUNDLE_ID = "nl.luimes.resonance";
/** A cold launch, with the collection's indexes, can take this long. */
const LAUNCH_WAIT_MS = 20_000;
const ANSWER_WAIT_MS = 30_000;

/** Where the app listens, the sandboxed build's folder as well as the plain one. */
function socketPaths(): string[] {
  if (process.env.RESONANCE_SOCKET) return [process.env.RESONANCE_SOCKET];
  const support = "Library/Application Support/Resonance/control.sock";
  return [join(homedir(), support), join(homedir(), "Library/Containers", BUNDLE_ID, "Data", support)];
}

function open(path: string): Promise<Socket | null> {
  return new Promise((resolve) => {
    const socket = connect(path);
    socket.once("connect", () => {
      socket.removeAllListeners("error");
      resolve(socket);
    });
    socket.once("error", () => resolve(null));
  });
}

async function tryConnect(): Promise<Socket | null> {
  for (const path of socketPaths()) {
    const socket = await open(path);
    if (socket) return socket;
  }
  return null;
}

function launch(): Promise<void> {
  return new Promise((resolve, reject) => {
    execFile("/usr/bin/open", ["-g", "-b", BUNDLE_ID], (error) => {
      if (error) reject(new Error("Couldn't start Resonance. Is it installed?"));
      else resolve();
    });
  });
}

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

/** Connect, starting the app if it isn't running. */
async function connectToApp(): Promise<Socket> {
  const socket = await tryConnect();
  if (socket) return socket;
  if (process.env.RESONANCE_NO_LAUNCH) throw new Error("Resonance isn't running.");
  await launch();
  const deadline = Date.now() + LAUNCH_WAIT_MS;
  while (Date.now() < deadline) {
    await sleep(150);
    const launched = await tryConnect();
    if (launched) return launched;
  }
  throw new Error("Resonance didn't answer. It may be older than this extension: update it, then try again.");
}

function exchange(socket: Socket, request: string): Promise<string> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    const lost = () => reject(new Error("Lost touch with Resonance."));
    socket.setTimeout(ANSWER_WAIT_MS, () => reject(new Error("Resonance took too long to answer.")));
    socket.on("data", (chunk) => {
      const bytes = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
      chunks.push(bytes);
      // A newline can't fall inside a character in UTF-8, so finding it in the
      // bytes is safe however the answer was split.
      if (bytes.includes(10)) resolve(Buffer.concat(chunks).toString("utf8"));
    });
    socket.once("error", lost);
    socket.once("end", lost);
    socket.write(request);
  });
}

/** Ask, and get the answer's `result`. Throws with the app's own words if it says no. */
export async function call<T = unknown>(cmd: string, args: Record<string, unknown> = {}): Promise<T> {
  const socket = await connectToApp();
  try {
    const line = await exchange(socket, JSON.stringify({ id: 1, cmd, args }) + "\n");
    let answer: { ok?: boolean; result?: T; error?: string };
    try {
      answer = JSON.parse(line);
    } catch {
      throw new Error("Resonance's answer couldn't be read.");
    }
    if (answer.ok !== true) throw new Error(answer.error ?? "Something went wrong.");
    return answer.result as T;
  } finally {
    socket.destroy();
  }
}

export const status = () => call<Status>("status");
export const search = (text: string, limit = 50) => call<Tune[]>("search", { text, limit });
export const like = (path?: string, limit = 30) => call<Tune[]>("like", { path, limit });
export const describe = (text: string) => call<Described>("describe", { text, play: false });
export const recent = (limit = 100) => call<Tune[]>("recent", { limit });
export const sound = (path: string) => call<Sound>("sound", { path });
export const prints = (paths: string[]) => call<Print[]>("prints", { paths });
export const playlists = () => call<PlaylistInfo[]>("playlist.list");
export const playlistTunes = (name: string) => call<Tune[]>("playlist.show", { name });

/** Play a list, starting at `start`. With `query`, the app says it's playing from that search. */
export const playTunes = (paths: string[], start?: string, query?: string) =>
  call("play", { paths, start, text: query });
export const playPlaylist = (name: string, start?: string) => call("playlist.play", { name, start });
export const addToPlaylist = (name: string, paths: string[]) => call("playlist.add", { name, paths });
export const removeFromPlaylist = (name: string, paths: string[]) => call("playlist.rm", { name, paths });
export const setFavourite = (on: boolean) => call<Tune>("fav", { on });
export const showInApp = (path: string) => call("show", { path });
export const startDrift = (path?: string) => call("drift", { path });

/**
 * What's playing once a skip has taken hold. The app answers before the new tune
 * has loaded, so ask until the tune changes, and settle for what's there if it
 * doesn't, as at the end of a list.
 */
export async function afterSkip(previousPath: string | undefined, tries = 10, waitMs = 150): Promise<Status> {
  let current = await status();
  for (let attempt = 0; attempt < tries && current.now?.path === previousPath; attempt++) {
    await sleep(waitMs);
    current = await status();
  }
  return current;
}
