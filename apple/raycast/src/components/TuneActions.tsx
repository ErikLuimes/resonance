import { Action, ActionPanel, Icon, Keyboard } from "@raycast/api";
import { useCachedPromise } from "@raycast/utils";
import { useState } from "react";
import { addToPlaylist, playlists, showInApp, startDrift, type Tune } from "../lib/client";
import { byline } from "../lib/format";
import { closeWith, stayWith } from "./run";
import { SoundsLikeList } from "./SoundsLikeList";

/** Favorites and your playlists, asked for only when the menu opens. */
export function AddToPlaylist({ paths }: { paths: string[] }) {
  const [opened, setOpened] = useState(false);
  const { data, isLoading } = useCachedPromise(playlists, [], { execute: opened });
  return (
    <ActionPanel.Submenu
      title="Add to Playlist…"
      icon={Icon.Plus}
      shortcut={{ modifiers: ["cmd", "shift"], key: "p" }}
      isLoading={isLoading}
      onOpen={() => setOpened(true)}
    >
      {(data ?? []).map((list) => (
        <Action
          key={list.name}
          title={list.name}
          icon={list.isFavorites ? Icon.Star : Icon.List}
          onAction={() => stayWith(`Added to ${list.name}`, () => addToPlaylist(list.name, paths))}
        />
      ))}
    </ActionPanel.Submenu>
  );
}

/** What every tune offers, after Play. */
export function TuneActions({ tune }: { tune: Tune }) {
  return (
    <>
      <ActionPanel.Section>
        <Action.Push
          title="Sounds Like This"
          icon={Icon.Waveform}
          shortcut={{ modifiers: ["cmd"], key: "l" }}
          target={<SoundsLikeList seed={tune} />}
        />
        <Action
          title="Start Sound Drift"
          icon={Icon.Shuffle}
          shortcut={{ modifiers: ["cmd", "shift"], key: "d" }}
          onAction={() => closeWith(`Drifting from ${tune.title}`, () => startDrift(tune.path))}
        />
        <AddToPlaylist paths={[tune.path]} />
      </ActionPanel.Section>
      <ActionPanel.Section>
        <Action
          title="Show in Resonance"
          icon={Icon.AppWindow}
          shortcut={Keyboard.Shortcut.Common.Open}
          onAction={() => closeWith(`Showing ${tune.title}`, () => showInApp(tune.path))}
        />
        <Action.ShowInFinder path={tune.path} shortcut={{ modifiers: ["cmd", "shift"], key: "f" }} />
        <Action.CopyToClipboard
          title="Copy Title and Composer"
          content={byline(tune.title, tune.author)}
          shortcut={Keyboard.Shortcut.Common.Copy}
        />
      </ActionPanel.Section>
    </>
  );
}
