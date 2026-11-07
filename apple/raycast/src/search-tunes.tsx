import type { LaunchProps } from "@raycast/api";
import { useCachedPromise } from "@raycast/utils";
import { useState } from "react";
import { TuneList } from "./components/TuneList";
import { playTunes, search } from "./lib/client";

const find = (text: string) => (text.trim() ? search(text.trim()) : Promise.resolve([]));

export default function Command(props: LaunchProps<{ arguments: { query?: string } }>) {
  // Typed after the alias, or from Raycast's search when this is a fallback command.
  const [text, setText] = useState(props.arguments.query || props.fallbackText || "");
  const { data, isLoading, error } = useCachedPromise(find, [text], {
    keepPreviousData: true,
    onError: () => undefined,
  });
  const tunes = data ?? [];
  return (
    <TuneList
      tunes={tunes}
      isLoading={isLoading}
      errorMessage={error?.message}
      empty={
        text.trim()
          ? { title: "No tunes found", description: "Try a composer, or a word from the title." }
          : { title: "Search the collection", description: "By title or composer, such as hubbard commando." }
      }
      searchBarPlaceholder="Search by title or composer"
      searchText={text}
      onSearchTextChange={setText}
      throttle
      filtering={false}
      detailKey="search"
      detailByDefault
      play={(tune) =>
        playTunes(
          tunes.map((item) => item.path),
          tune.path,
          text.trim(),
        )
      }
    />
  );
}
