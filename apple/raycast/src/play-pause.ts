import { runCommand } from "./components/run";
import { togglePlayback } from "./lib/controls";

export default async function Command() {
  await runCommand(togglePlayback);
}
