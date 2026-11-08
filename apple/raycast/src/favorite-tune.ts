import { runCommand } from "./components/run";
import { setFavorite, status } from "./lib/client";

export default async function Command() {
  await runCommand(async () => {
    const { favorite } = await status();
    const tune = await setFavorite(!favorite);
    return favorite ? `Took ${tune.title} out of Favorites` : `Added ${tune.title} to Favorites`;
  });
}
