import { runCommand } from "./components/run";
import { previousTune } from "./lib/controls";

export default async function Command() {
  await runCommand(previousTune);
}
