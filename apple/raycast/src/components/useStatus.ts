import { useCallback, useEffect, useRef, useState } from "react";
import { status } from "../lib/client";
import { afterPoll, type Polled } from "../lib/poll";

/** What the app is playing, asked for every second, rendering only when what's shown changes. */
export function useStatus() {
  const [polled, setPolled] = useState<Polled>({ isLoading: true });
  const lastCall = useRef(0);

  const revalidate = useCallback(async () => {
    const call = ++lastCall.current;
    const result = await status().then(
      (data) => ({ data }),
      (error: Error) => ({ error }),
    );
    // A slow answer doesn't overwrite a newer one.
    if (call === lastCall.current) setPolled((previous) => afterPoll(previous, result));
  }, []);

  useEffect(() => {
    revalidate();
    const timer = setInterval(revalidate, 1000);
    return () => clearInterval(timer);
  }, [revalidate]);

  return { ...polled, revalidate };
}
