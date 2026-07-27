import { initials } from "../lib/format";

export function AvatarBadge({
  name,
  presence = "unknown",
  size = "medium"
}: {
  name: string;
  presence?: "online" | "offline" | "unknown";
  size?: "small" | "medium" | "large";
}) {
  return (
    <span className={`member-avatar member-avatar-${size}`} aria-hidden="true">
      {initials(name)}
      {presence !== "unknown" && <span className={`presence-dot ${presence}`} />}
    </span>
  );
}
