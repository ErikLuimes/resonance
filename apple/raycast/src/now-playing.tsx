import { Action, ActionPanel, Detail, Icon, Keyboard } from "@raycast/api";
import { useCachedPromise } from "@raycast/utils";
import { useEffect } from "react";
import { SoundsLikeList } from "./components/SoundsLikeList";
import { AddToPlaylist } from "./components/TuneActions";
import { soundMarkdown, soundOrNothing } from "./components/TuneDetail";
import { closeWith, quietly } from "./components/run";
import { call, prints, setFavourite, showInApp, startDrift, status, type Tune } from "./lib/client";
import { clock, spokenName } from "./lib/format";

async function fingerprint(path?: string) {
  if (!path) return null;
  const [found] = await prints([path]);
  return found?.traits ?? null;
}

export default function Command() {
  const { data, error, isLoading, revalidate } = useCachedPromise(status, [], {
    keepPreviousData: true,
    onError: () => undefined,
  });
  const now = data?.now ?? null;
  const path = now?.path;
  const { data: described } = useCachedPromise(soundOrNothing, [path ?? ""], { execute: path != null });
  const { data: traits } = useCachedPromise(fingerprint, [path]);

  // The elapsed time, and the tune when it moves on by itself.
  useEffect(() => {
    const timer = setInterval(revalidate, 1000);
    return () => clearInterval(timer);
  }, [revalidate]);

  const send = (cmd: string) => () =>
    quietly(async () => {
      await call(cmd);
      revalidate();
    });
  const tune: Tune | null = now && { path: now.path, title: now.title, author: now.author, released: now.released };
  const stillLoading = isLoading && !data;

  return (
    <Detail
      isLoading={stillLoading}
      markdown={
        now
          ? soundMarkdown(now.title, described?.summary, traits ?? undefined)
          : stillLoading
            ? ""
            : `## ${error?.message ?? "Nothing is playing"}`
      }
      metadata={
        now && data ? (
          <Detail.Metadata>
            {now.author ? <Detail.Metadata.Label title="Composer" text={spokenName(now.author)} /> : null}
            {now.released ? <Detail.Metadata.Label title="Released" text={now.released} /> : null}
            <Detail.Metadata.Label
              title={data.state === "paused" ? "Paused at" : "Time"}
              text={data.duration ? `${clock(data.elapsed)} of ${clock(data.duration)}` : clock(data.elapsed)}
            />
            {now.songs > 1 ? <Detail.Metadata.Label title="Subtune" text={`${now.song} of ${now.songs}`} /> : null}
            {data.source ? <Detail.Metadata.Label title="Playing From" text={data.source} /> : null}
            {data.favourite ? <Detail.Metadata.Label title="In Favorites" text="Yes" /> : null}
            {described?.tags.length ? (
              <Detail.Metadata.TagList title="Sound">
                {described.tags.map((tag) => (
                  <Detail.Metadata.TagList.Item key={tag} text={tag} />
                ))}
              </Detail.Metadata.TagList>
            ) : null}
          </Detail.Metadata>
        ) : null
      }
      actions={
        <ActionPanel>
          <ActionPanel.Section>
            {now ? (
              <Action
                title={data?.state === "playing" ? "Pause" : "Play"}
                icon={data?.state === "playing" ? Icon.Pause : Icon.Play}
                onAction={send("toggle")}
              />
            ) : (
              <Action title="Surprise Me" icon={Icon.Stars} onAction={send("surprise")} />
            )}
            <Action
              title="Next Tune"
              icon={Icon.Forward}
              shortcut={{ modifiers: ["cmd"], key: "arrowRight" }}
              onAction={send("next")}
            />
            <Action
              title="Previous Tune"
              icon={Icon.Rewind}
              shortcut={{ modifiers: ["cmd"], key: "arrowLeft" }}
              onAction={send("prev")}
            />
          </ActionPanel.Section>
          {tune ? (
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
              <Action
                title={data?.favourite ? "Remove from Favorites" : "Add to Favorites"}
                icon={data?.favourite ? Icon.StarDisabled : Icon.Star}
                shortcut={{ modifiers: ["cmd", "shift"], key: "b" }}
                onAction={() =>
                  quietly(async () => {
                    await setFavourite(!data?.favourite);
                    revalidate();
                  })
                }
              />
              <AddToPlaylist paths={[tune.path]} />
              <Action
                title="Show in Resonance"
                icon={Icon.AppWindow}
                shortcut={Keyboard.Shortcut.Common.Open}
                onAction={() => closeWith(`Showing ${tune.title}`, () => showInApp(tune.path))}
              />
            </ActionPanel.Section>
          ) : null}
        </ActionPanel>
      }
    />
  );
}
