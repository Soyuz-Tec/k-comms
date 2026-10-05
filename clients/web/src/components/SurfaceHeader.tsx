import type { ReactNode } from "react";
import { Link } from "react-router";
import { AppIcon } from "./AppIcon";

interface SurfaceHeaderProps {
  title: string;
  description?: string;
  eyebrow?: string;
  actions?: ReactNode;
  back?: { to: string; label: string };
  className?: string;
}

export function SurfaceHeader({ title, description, eyebrow, actions, back, className = "" }: SurfaceHeaderProps) {
  return <header className={`surface-header page-heading ${className}`}>
    <div className="surface-header-copy">
      {back && <Link className="surface-back" to={back.to}><AppIcon name="arrowLeft" />{back.label}</Link>}
      {eyebrow && <span className="eyebrow">{eyebrow}</span>}
      <h1>{title}</h1>
      {description && <p>{description}</p>}
    </div>
    {actions && <div className="surface-actions">{actions}</div>}
  </header>;
}
