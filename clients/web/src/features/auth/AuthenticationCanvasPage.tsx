import type { ReactNode } from "react";

export function AuthenticationCanvasPage({
  workspace,
  gateway
}: {
  workspace: ReactNode;
  gateway: ReactNode;
}) {
  return (
    <div className="auth-page">
      <div
        className="auth-canvas-backdrop"
        data-testid="authentication-canvas"
        aria-hidden="true"
        inert
      >
        {workspace}
      </div>
      {gateway}
    </div>
  );
}
