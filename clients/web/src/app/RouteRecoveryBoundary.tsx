import { Component, useEffect, useRef, type ReactNode } from "react";
import { Link, useLocation } from "react-router";

interface BoundaryProps {
  children: ReactNode;
  resetKey: string;
  reload: () => void;
}

interface BoundaryState {
  error: unknown;
  failed: boolean;
  resetKey: string;
}

class RecoveryBoundary extends Component<BoundaryProps, BoundaryState> {
  constructor(props: BoundaryProps) {
    super(props);
    this.state = { error: null, failed: false, resetKey: props.resetKey };
  }

  static getDerivedStateFromError(error: unknown) {
    return { error, failed: true };
  }

  static getDerivedStateFromProps(props: BoundaryProps, state: BoundaryState) {
    // Reset only failed content on navigation. A key on this boundary would
    // remount healthy call/session owners whenever the route changes.
    return props.resetKey === state.resetKey
      ? null
      : { error: null, failed: false, resetKey: props.resetKey };
  }

  render() {
    if (!this.state.failed) return this.props.children;
    return <RecoveryPage
      moduleFailure={isModuleLoadFailure(this.state.error)}
      retry={() => this.setState({ error: null, failed: false })}
      reload={this.props.reload}
    />;
  }
}

export function RouteRecoveryBoundary({ children, reload = () => window.location.reload() }: {
  children: ReactNode;
  reload?: () => void;
}) {
  const location = useLocation();
  return <RecoveryBoundary resetKey={location.key} reload={reload}>{children}</RecoveryBoundary>;
}

function isModuleLoadFailure(error: unknown): boolean {
  return error instanceof Error && /dynamically imported module|importing a module script failed|loading chunk|load module script|preload css|chunkloaderror/i.test(`${error.name} ${error.message}`);
}

function RecoveryPage({ moduleFailure, retry, reload }: {
  moduleFailure: boolean;
  retry: () => void;
  reload: () => void;
}) {
  const heading = useRef<HTMLHeadingElement>(null);
  useEffect(() => heading.current?.focus(), []);
  return <main id="main-content" className="page-shell">
    <section className="data-card" aria-labelledby="route-recovery-title">
      <h1 ref={heading} id="route-recovery-title" tabIndex={-1}>This page could not open</h1>
      <p role="alert">{moduleFailure
        ? "Some application files could not load. Check your connection, then reload K-Comms."
        : "Something interrupted this page. You can try opening it again or return to your inbox."}</p>
      <p>Before reloading, finish any active call and copy drafts kept only in this tab.</p>
      <div className="actions">
        {!moduleFailure && <button type="button" className="button primary" onClick={retry}>Try again</button>}
        <Link className="button ghost" to="/app/">Open Inbox</Link>
        <button type="button" className="button ghost" onClick={reload}>Reload K-Comms</button>
      </div>
    </section>
  </main>;
}
