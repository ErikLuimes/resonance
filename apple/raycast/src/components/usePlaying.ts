import { useEffect, useState } from "react";
import { statusIfRunning } from "../lib/client";
import { playingFrom, samePlaying, type Playing } from "../lib/poll";

/** The tune playing or paused, asked for every second, rendering only when it changes. */
export function usePlaying(): Playing {
  const [playing, setPlaying] = useState<Playing>(null);

  useEffect(() => {
    let lastCall = 0;
    const refresh = async () => {
      const call = ++lastCall;
      const next = playingFrom(await statusIfRunning().catch(() => null));
      if (call === lastCall) setPlaying((previous) => samePlaying(previous, next));
    };
    refresh();
    const timer = setInterval(refresh, 1000);
    return () => clearInterval(timer);
  }, []);

  return playing;
}
