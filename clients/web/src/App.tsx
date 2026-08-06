import { lazy, Suspense } from "react";
import { BrowserRouter, Navigate, Route, Routes, useLocation } from "react-router";
import { ProductShell } from "./app/ProductShell";
import { RouteOrientation } from "./app/RouteOrientation";
import { SessionProvider, useSession } from "./app/session";
import { WorkspaceDataProvider } from "./app/workspace-data";
import { StepUpProvider } from "./app/step-up";
import { AuthScreen } from "./features/auth/AuthScreen";
import { ForgotPasswordPage, ResetPasswordPage } from "./features/auth/PasswordRecoveryPages";
import { GuestAccessPage } from "./features/guest/GuestAccessPage";
import { InstantRoomPage } from "./features/instant-room/InstantRoomPage";
import "./fonts.css";
import "./theme.css";
import "./styles.css";
import "./mobile-experience.css";
import "./desktop-experience.css";
import "./interface-system.css";

const AdminPage = lazy(() =>
  import("./features/admin/AdminPage").then(({ AdminPage: page }) => ({ default: page }))
);
const CallsPage = lazy(() =>
  import("./features/calls/CallsPage").then(({ CallsPage: page }) => ({ default: page }))
);
const ChatPage = lazy(() =>
  import("./features/chat/ChatPage").then(({ ChatPage: page }) => ({ default: page }))
);
const DirectoryPage = lazy(() =>
  import("./features/directory/DirectoryPage").then(({ DirectoryPage: page }) => ({ default: page }))
);
const FilesPage = lazy(() =>
  import("./features/files/FilesPage").then(({ FilesPage: page }) => ({ default: page }))
);
const WhiteboardPage = lazy(() =>
  import("./features/whiteboard/WhiteboardPage").then(({ WhiteboardPage: page }) => ({ default: page }))
);
const OpsPage = lazy(() =>
  import("./features/ops/OpsPage").then(({ OpsPage: page }) => ({ default: page }))
);
const YouPage = lazy(() =>
  import("./features/you/YouPage").then(({ YouPage: page }) => ({ default: page }))
);
export default function App() {
  return (
    <SessionProvider>
      <BrowserRouter>
        <ApplicationRoutes />
      </BrowserRouter>
    </SessionProvider>
  );
}

function ApplicationRoutes() {
  const { session, transportPolicyReady } = useSession();
  const location = useLocation();
  if (location.pathname === "/app") {
    return (
      <Navigate
        to={`/app/${location.search}${location.hash}`}
        replace
      />
    );
  }
  const normalizedPathname =
    location.pathname === "/"
      ? "/"
      : location.pathname.replace(/\/+$/, "");
  if (normalizedPathname === "/join") {
    return (
      <>
        <RouteOrientation authenticated={false} />
        <Routes>
          <Route path="/join" element={<GuestAccessPage />} />
        </Routes>
      </>
    );
  }

  if (location.pathname === "/") {
    return (
      <>
        <RouteOrientation authenticated={Boolean(session)} />
        <Routes>
          <Route path="/" element={<InstantRoomPage />} />
        </Routes>
      </>
    );
  }

  const publicAuthRoute = [
    "/forgot-password",
    "/reset-password",
    "/sign-in"
  ].includes(normalizedPathname);
  const invitationEntry =
    normalizedPathname === "/app" &&
    hasInvitationToken(location.search, location.hash);

  if (!transportPolicyReady && !publicAuthRoute && !invitationEntry) {
    return <RouteLoading />;
  }

  if (!session) {
    return (
      <Routes>
        <Route path="/forgot-password" element={<><RouteOrientation authenticated={false} /><ForgotPasswordPage /></>} />
        <Route path="/reset-password" element={<><RouteOrientation authenticated={false} /><ResetPasswordPage /></>} />
        <Route
          path="/sign-in"
          element={
            <InstantRoomPage
              authenticationGateway={<AuthScreen embedded />}
            />
          }
        />
        <Route
          path="/app/"
          element={
            <Navigate
              to={`/sign-in${location.search}${location.hash}`}
              replace
            />
          }
        />
        <Route path="*" element={<Navigate to="/sign-in" replace />} />
      </Routes>
    );
  }

  return (
    <>
      <RouteOrientation authenticated />
      <WorkspaceDataProvider>
        <StepUpProvider>
          <Suspense fallback={<RouteLoading />}>
            <Routes>
              <Route element={<ProductShell />}>
                <Route path="/app/" element={<ChatPage />} />
                <Route path="/app/calls" element={<CallsPage />} />
                <Route path="/app/directory" element={<DirectoryPage />} />
                <Route path="/app/files" element={<FilesPage />} />
                <Route path="/app/whiteboard" element={<WhiteboardPage />} />
                <Route path="/app/you" element={<YouPage />} />
                <Route path="/app/settings" element={<Navigate to="/app/you" replace />} />
                <Route path="/admin" element={<AdminPage />} />
                <Route path="/ops" element={<OpsPage />} />
              </Route>
              <Route
                path="/sign-in"
                element={
                  <Navigate
                    to={memberAppTarget(location.search)}
                    replace
                  />
                }
              />
              <Route path="*" element={<Navigate to="/app/" replace />} />
            </Routes>
          </Suspense>
        </StepUpProvider>
      </WorkspaceDataProvider>
    </>
  );
}

function hasInvitationToken(search: string, hash: string): boolean {
  return (
    new URLSearchParams(search).has("invitation_token") ||
    new URLSearchParams(hash.replace(/^#/, "")).has("invitation_token")
  );
}

export function memberAppTarget(search: string): string {
  const source = new URLSearchParams(search);
  const target = new URLSearchParams();
  for (const name of [
    "conversation",
    "message",
    "search_message",
    "search_sequence",
    "call"
  ]) {
    const value = source.get(name);
    if (value) target.set(name, value);
  }
  const query = target.toString();
  return query ? `/app/?${query}` : "/app/";
}

function RouteLoading() {
  return (
    <main className="route-loading" id="main-content" aria-busy="true">
      <span className="spinner" aria-hidden="true" />
      <h1>Loading K-Comms…</h1>
    </main>
  );
}
