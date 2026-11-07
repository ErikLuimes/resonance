import { showHUD, showToast, Toast } from "@raycast/api";

const message = (error: unknown) => (error instanceof Error ? error.message : String(error));

/** For a command with no window: the outcome, or the app's reason, as a HUD. */
export async function runCommand(work: () => Promise<string>) {
  try {
    await showHUD(await work());
  } catch (error) {
    await showHUD(message(error));
  }
}

/** For an action that closes Raycast, such as playing. */
export async function closeWith(hud: string, work: () => Promise<unknown>) {
  try {
    await work();
    await showHUD(hud);
  } catch (error) {
    await showToast({ style: Toast.Style.Failure, title: message(error) });
  }
}

/** For a control whose result shows by itself, such as Next Tune in Now Playing. */
export async function quietly(work: () => Promise<unknown>) {
  try {
    await work();
  } catch (error) {
    await showToast({ style: Toast.Style.Failure, title: message(error) });
  }
}

/** For an action that stays in the list, such as adding to a playlist. */
export async function stayWith(done: string, work: () => Promise<unknown>) {
  const toast = await showToast({ style: Toast.Style.Animated, title: "Working" });
  try {
    await work();
    toast.style = Toast.Style.Success;
    toast.title = done;
  } catch (error) {
    toast.style = Toast.Style.Failure;
    toast.title = message(error);
  }
}
