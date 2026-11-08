import { Action, ActionPanel, Icon, List } from "@raycast/api";
import { useCachedPromise } from "@raycast/utils";
import { closeWith, stayWith } from "./components/run";
import { TuneList } from "./components/TuneList";
import { playlists, playlistTunes, playPlaylist, removeFromPlaylist, type PlaylistInfo } from "./lib/client";

function PlaylistTunes({ list }: { list: PlaylistInfo }) {
  const { data, isLoading, error, revalidate } = useCachedPromise(playlistTunes, [list.name], {
    onError: () => undefined,
  });
  return (
    <TuneList
      tunes={data ?? []}
      isLoading={isLoading}
      errorMessage={error?.message}
      empty={{ title: `${list.name} has no tunes in it` }}
      navigationTitle={list.name}
      searchBarPlaceholder={`Filter ${list.name}`}
      detailKey="playlist"
      detailByDefault
      play={(tune) => playPlaylist(list.name, tune.path)}
      extraActions={(tune) => (
        <ActionPanel.Section>
          <Action
            title={`Remove from ${list.name}`}
            icon={Icon.Minus}
            style={Action.Style.Destructive}
            shortcut={{ modifiers: ["ctrl"], key: "x" }}
            onAction={async () => {
              await stayWith(`Took ${tune.title} out`, () => removeFromPlaylist(list.name, [tune.path]));
              revalidate();
            }}
          />
        </ActionPanel.Section>
      )}
    />
  );
}

export default function Command() {
  const { data, isLoading, error } = useCachedPromise(playlists, [], { onError: () => undefined });
  return (
    <List isLoading={isLoading} searchBarPlaceholder="Filter playlists">
      {!data?.length && !isLoading ? (
        <List.EmptyView icon={Icon.List} title={error?.message ?? "No playlists"} />
      ) : null}
      {(data ?? []).map((list) => (
        <List.Item
          key={list.name}
          title={list.name}
          icon={list.isFavorites ? Icon.Star : Icon.List}
          accessories={[{ text: list.count === 1 ? "1 tune" : `${list.count} tunes` }]}
          actions={
            <ActionPanel>
              <Action.Push title="Open Playlist" icon={Icon.List} target={<PlaylistTunes list={list} />} />
              <Action
                title="Play Playlist"
                icon={Icon.Play}
                onAction={() => closeWith(`Playing ${list.name}`, () => playPlaylist(list.name))}
              />
            </ActionPanel>
          }
        />
      ))}
    </List>
  );
}
