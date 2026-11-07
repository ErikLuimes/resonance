import { useCachedPromise } from "@raycast/utils";
import { TuneList } from "./components/TuneList";
import { recent } from "./lib/client";

export default function Command() {
  const { data, isLoading, error } = useCachedPromise(() => recent(), [], { onError: () => undefined });
  return (
    <TuneList
      tunes={data ?? []}
      isLoading={isLoading}
      errorMessage={error?.message}
      empty={{ title: "Nothing played yet" }}
      searchBarPlaceholder="Filter recently played"
      detailKey="recent"
      detailByDefault
    />
  );
}
