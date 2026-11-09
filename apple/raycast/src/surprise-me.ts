import { runCommand } from "./components/run";
import { surpriseMe } from "./lib/controls";

export default async function Command() {
  await runCommand(surpriseMe);
}
