import { runCommand } from "./components/run";
import { setFavourite, status } from "./lib/client";

export default async function Command() {
  await runCommand(async () => {
    const { favourite } = await status();
    const tune = await setFavourite(!favourite);
    return favourite ? `Took ${tune.title} out of Favourites` : `Added ${tune.title} to Favourites`;
  });
}
