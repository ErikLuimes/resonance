import { runCommand } from "./components/run";
import { nextTune } from "./lib/controls";

export default async function Command() {
  await runCommand(nextTune);
}
