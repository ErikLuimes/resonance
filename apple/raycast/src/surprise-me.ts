import { runCommand } from "./components/run";
import { afterSkip, call, status } from "./lib/client";
import { byline } from "./lib/format";

export default async function Command() {
  await runCommand(async () => {
    const before = await status();
    await call("surprise");
    const after = await afterSkip(before.now?.path);
    return after.now ? byline(after.now.title, after.now.author) : "Surprise on its way";
  });
}
