import { Action, ActionPanel, Icon, List } from "@raycast/api";
import { useCachedPromise, useCachedState } from "@raycast/utils";
import type { ComponentProps, ReactNode } from "react";
import { useMemo, useState } from "react";
import { playTunes, prints, type Tune } from "../lib/client";
import { barcode, byline, percent, spokenName } from "../lib/format";
import { TuneActions } from "./TuneActions";
import { closeWith } from "./run";
import { TuneDetail } from "./TuneDetail";

type TuneListProps = {
  tunes: Tune[];
  isLoading: boolean;
  /** Why there are no tunes, in the app's words. */
  errorMessage?: string;
  empty: { title: string; description?: string };
  /** A line over the list, as Describe's note. */
  sectionTitle?: string;
  /** Lists remember separately, as comparing bars down a list wants the pane closed. */
  detailKey: string;
  detailByDefault: boolean;
  /** Play from this tune; by default the list as a queue, starting here. */
  play?: (tune: Tune) => Promise<unknown>;
  extraActions?: (tune: Tune) => ReactNode;
} & Pick<
  ComponentProps<typeof List>,
  "navigationTitle" | "searchBarPlaceholder" | "searchText" | "onSearchTextChange" | "throttle" | "filtering"
>;

const fingerprints = (paths: string[]) => (paths.length ? prints(paths) : Promise.resolve([]));

export function TuneList(props: TuneListProps) {
  const { tunes, isLoading, errorMessage, empty, sectionTitle, detailKey, detailByDefault, play, extraActions } = props;
  const { navigationTitle, searchBarPlaceholder, searchText, onSearchTextChange, throttle, filtering } = props;
  const [showingDetail, setShowingDetail] = useCachedState(`detail-${detailKey}`, detailByDefault);
  const [selected, setSelected] = useState<string | null>(null);

  const paths = useMemo(() => tunes.map((tune) => tune.path), [tunes]);
  const { data: found } = useCachedPromise(fingerprints, [paths], { keepPreviousData: true });
  const traits = useMemo(() => new Map((found ?? []).map((print) => [print.path, print.traits])), [found]);

  const items = tunes.map((tune, index) => {
    // The same tune can be in a playlist twice.
    const id = `${index}:${tune.path}`;
    const print = traits.get(tune.path);
    const start = () => (play ? play(tune) : playTunes(paths, tune.path));
    return (
      <List.Item
        key={id}
        id={id}
        title={tune.title}
        subtitle={spokenName(tune.author)}
        keywords={[spokenName(tune.author), tune.released]}
        accessories={
          showingDetail
            ? undefined
            : [
                ...(tune.score != null ? [{ text: percent(tune.score), tooltip: "How alike" }] : []),
                ...(print ? [{ text: barcode(print), tooltip: "How it sounds" }] : []),
                ...(tune.released ? [{ text: tune.released.slice(0, 4), tooltip: tune.released }] : []),
              ]
        }
        detail={
          // Every row's detail is rendered, so only the selected one asks the app.
          showingDetail && (selected === id || (selected === null && index === 0)) ? (
            <TuneDetail tune={tune} traits={print} />
          ) : (
            <List.Item.Detail />
          )
        }
        actions={
          <ActionPanel>
            <ActionPanel.Section>
              <Action
                title="Play"
                icon={Icon.Play}
                onAction={() => closeWith(`Playing ${byline(tune.title, tune.author)}`, start)}
              />
              <Action
                title={showingDetail ? "Hide Sound" : "Show Sound"}
                icon={Icon.Sidebar}
                shortcut={{ modifiers: ["cmd"], key: "d" }}
                onAction={() => setShowingDetail(!showingDetail)}
              />
            </ActionPanel.Section>
            <TuneActions tune={tune} />
            {extraActions?.(tune)}
          </ActionPanel>
        }
      />
    );
  });

  return (
    <List
      isLoading={isLoading}
      isShowingDetail={showingDetail && tunes.length > 0}
      navigationTitle={navigationTitle}
      searchBarPlaceholder={searchBarPlaceholder}
      searchText={searchText}
      onSearchTextChange={onSearchTextChange}
      throttle={throttle}
      filtering={filtering}
      onSelectionChange={setSelected}
    >
      {tunes.length === 0 && !isLoading ? (
        <List.EmptyView
          icon={Icon.Music}
          title={errorMessage ?? empty.title}
          description={errorMessage ? undefined : empty.description}
        />
      ) : sectionTitle ? (
        <List.Section title={sectionTitle}>{items}</List.Section>
      ) : (
        items
      )}
    </List>
  );
}
