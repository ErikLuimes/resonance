import { runCommand } from "./components/run";
import { call, status } from "./lib/client";

export default async function Command() {
  await runCommand(async () => {
    await call("toggle");
    const current = await status();
    if (!current.now) return "Nothing to play";
    return current.state === "playing" ? `Playing ${current.now.title}` : `Paused ${current.now.title}`;
  });
}
