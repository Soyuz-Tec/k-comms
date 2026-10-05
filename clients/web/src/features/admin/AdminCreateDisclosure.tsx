import type { ReactNode } from "react";
import { AppIcon } from "../../components/AppIcon";
import "./EvidencePanels.css";

/** Keep resource inventory visible and retain drafts when a creation form is collapsed. */
export function AdminCreateDisclosure({ label, children, defaultOpen = false }: { label: string; children: ReactNode; defaultOpen?: boolean }) {
  return <details className="admin-create-disclosure" open={defaultOpen || undefined}>
    <summary className="button secondary compact" tabIndex={0}><span>{label}</span><AppIcon name="chevronDown" /></summary>
    <div className="admin-create-content">{children}</div>
  </details>;
}
