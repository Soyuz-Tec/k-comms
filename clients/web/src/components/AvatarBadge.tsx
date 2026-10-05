import { initials } from "../lib/format";

export function AvatarBadge({
  name,
  avatarUrl,
  presence = "unknown",
  size = "medium"
}: {
  name: string;
  avatarUrl?: string | null;
  presence?: "online" | "offline" | "unknown";
  size?: "small" | "medium" | "large";
}) {
  return (
    <span className={`member-avatar member-avatar-${size}`} aria-hidden="true">
      {avatarUrl && avatarUrl.length <= 180_000 && /^data:image\/png;base64,[A-Za-z0-9+/]+={0,2}$/.test(avatarUrl)
        ? <img src={avatarUrl} alt="" width="100%" height="100%" style={{ objectFit: "cover", borderRadius: "inherit" }} />
        : initials(name)}
      {presence !== "unknown" && <span className={`presence-dot ${presence}`} />}
    </span>
  );
}
