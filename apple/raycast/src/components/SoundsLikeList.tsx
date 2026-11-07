import { usePromise } from "@raycast/utils";
import { like, status, type Tune } from "../lib/client";
import { TuneList } from "./TuneList";

/** Tunes like `seed`, or like the one playing. */
async function find(path?: string, title?: string) {
  if (path) return { title, tunes: await like(path) };
  const current = await status();
  if (!current.now) throw new Error("Nothing is playing.");
  return { title: current.now.title, tunes: await like(current.now.path) };
}

export function SoundsLikeList({ seed }: { seed?: Tune }) {
  // Not cached: what's playing now is the question, not what was last time.
  const { data, isLoading, error } = usePromise(find, [seed?.path, seed?.title], { onError: () => undefined });
  return (
    <TuneList
      tunes={data?.tunes ?? []}
      isLoading={isLoading}
      errorMessage={error?.message}
      empty={{ title: "No tunes found" }}
      navigationTitle={data?.title ? `Sounds Like ${data.title}` : "Sounds Like"}
      searchBarPlaceholder="Filter these tunes"
      detailKey="sounds-like"
      detailByDefault={false}
    />
  );
}
