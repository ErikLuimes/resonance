import type { LaunchProps } from "@raycast/api";
import { useCachedPromise } from "@raycast/utils";
import { TuneList } from "./components/TuneList";
import { describe } from "./lib/client";

export default function Command(props: LaunchProps<{ arguments: { text: string } }>) {
  const { text } = props.arguments;
  const { data, isLoading, error } = useCachedPromise(describe, [text], { onError: () => undefined });
  return (
    <TuneList
      tunes={data?.tunes ?? []}
      isLoading={isLoading}
      errorMessage={error?.message}
      empty={{ title: "No tunes fit that" }}
      navigationTitle={data?.title ?? text}
      sectionTitle={data?.note ?? undefined}
      searchBarPlaceholder="Filter these tunes"
      detailKey="describe"
      detailByDefault
    />
  );
}
