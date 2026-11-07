import { Color, List } from "@raycast/api";
import { useCachedPromise } from "@raycast/utils";
import { sound, type Tune } from "../lib/client";
import { clock, percent, spokenName, traitBars } from "../lib/format";

/** How the tune sounds, in the app's words and as its fingerprint. */
export function soundMarkdown(title: string, summary: string | undefined, traits: number[] | undefined): string {
  const parts = [`## ${title}`];
  if (summary) parts.push(summary);
  if (traits) parts.push("```\n" + traitBars(traits) + "\n```");
  else parts.push("Resonance hasn't fingerprinted this tune yet.");
  return parts.join("\n\n");
}

/** A tune without a fingerprint is ordinary, so not knowing how it sounds isn't an error. */
export const soundOrNothing = (path: string) => sound(path).catch(() => null);

export function TuneDetail({ tune, traits }: { tune: Tune; traits?: number[] }) {
  const { data, isLoading } = useCachedPromise(soundOrNothing, [tune.path]);
  return (
    <List.Item.Detail
      isLoading={isLoading}
      markdown={soundMarkdown(tune.title, data?.summary, traits)}
      metadata={
        <List.Item.Detail.Metadata>
          {tune.score != null ? <List.Item.Detail.Metadata.Label title="Alike" text={percent(tune.score)} /> : null}
          {tune.author ? <List.Item.Detail.Metadata.Label title="Composer" text={spokenName(tune.author)} /> : null}
          {tune.released ? <List.Item.Detail.Metadata.Label title="Released" text={tune.released} /> : null}
          {tune.secs != null ? <List.Item.Detail.Metadata.Label title="Length" text={clock(tune.secs)} /> : null}
          {(tune.songs ?? 0) > 1 ? <List.Item.Detail.Metadata.Label title="Subtunes" text={`${tune.songs}`} /> : null}
          {data?.tags.length ? (
            <List.Item.Detail.Metadata.TagList title="Sound">
              {data.tags.map((tag) => (
                <List.Item.Detail.Metadata.TagList.Item key={tag} text={tag} color={Color.SecondaryText} />
              ))}
            </List.Item.Detail.Metadata.TagList>
          ) : null}
        </List.Item.Detail.Metadata>
      }
    />
  );
}
