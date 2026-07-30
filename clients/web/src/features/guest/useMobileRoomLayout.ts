import { useEffect, useState } from "react";

const MOBILE_ROOM_QUERY = "(max-width: 760px), (max-height: 560px)";

export function useMobileRoomLayout(): boolean {
  const [mobile, setMobile] = useState(
    () => window.matchMedia?.(MOBILE_ROOM_QUERY).matches ?? false
  );

  useEffect(() => {
    if (!window.matchMedia) return;
    const query = window.matchMedia(MOBILE_ROOM_QUERY);
    const update = () => setMobile(query.matches);
    update();
    query.addEventListener?.("change", update);
    return () => query.removeEventListener?.("change", update);
  }, []);

  return mobile;
}
