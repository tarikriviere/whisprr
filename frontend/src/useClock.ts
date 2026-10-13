import { useEffect, useState } from "react";

/** Wall-clock unix seconds, ticking every second, for countdowns between vault refreshes. */
export function useClock(): bigint {
  const [now, setNow] = useState(() => BigInt(Math.floor(Date.now() / 1000)));
  useEffect(() => {
    const id = setInterval(() => setNow(BigInt(Math.floor(Date.now() / 1000))), 1_000);
    return () => clearInterval(id);
  }, []);
  return now;
}
