import { lazy, Suspense } from "react";
import { BrowserRouter, Navigate, Route, Routes, useLocation } from "react-router";
import { ProductShell } from "./app/ProductShell";
import { RouteOrientation } from "./app/RouteOrientation";
import { RouteRecoveryBoundary } from "./app/RouteRecoveryBoundary";
import { RouterHistoryProvider } from "./app/router-history";
import { PublicDesktopShell } from "./app/PublicDesktopShell";
import { DesktopThemeSync } from "./app/DesktopThemeSync";
import { SessionProvider, useSession } from "./app/session";
import { WorkspaceDataProvider } from "./app/workspace-data";
import { StepUpProvider } from "./app/step-up";
import { authenticationReturnTarget, guestContinuationState, safeMemberReturnTarget } from "./app/authNavigation";
import { AuthScreen } from "./features/auth/AuthScreen";
import { OidcCallback } from "./features/auth/OidcCallback";
import { ForgotPasswordPage, ResetPasswordPage } from "./features/auth/PasswordRecoveryPages";
import { GuestAccessPage } from "./features/guest/GuestAccessPage";
import { InstantRoomPage } from "./features/instant-room/InstantRoomPage";
import { validWorkspaceSlug } from "./lib/workspacePreference";
import "./fonts.css";
import "./theme.css";
import "./styles.css";
import "./mobile-experience.css";
import "./desktop-experience.css";
import "./interface-system.css";
/*
 * Last, deliberately. Immersive overrides shell layout that the sheets above
 * declare at the same specificity, and bundle order decides ties -- the same
 * ordering that silently picked the sidebar width in #163.
 */
import "./experience-mode.css";

const AdminPage = lazy(() =>
  import("./features/admin/AdminPage").then(({ AdminPage: page }) => ({ default: page }))
);
const PhonePage = lazy(() =>
  import("./features/telephony/PhonePage").then(({ PhonePage: page }) => ({ default: page }))
);
const MeetingsPage = lazy(() =>
  import("./features/meetings/MeetingsPage").then(({ MeetingsPage: page }) => ({ default: page }))
);
const MeetingArtifactsPage = lazy(() =>
  import("./features/meeting-artifacts/MeetingArtifactsPage").then(({ MeetingArtifactsPage: page }) => ({ default: page }))
);
const CallsPage = lazy(() =>
  import("./features/calls/CallsPage").then(({ CallsPage: page }) => ({ default: page }))
);
const ChatPage = lazy(() =>
  import("./features/chat/ChatPage").then(({ ChatPage: page }) => ({ default: page }))
);
const SavedItemsPage = lazy(() =>
  import("./features/chat/SavedItemsPage").then(({ SavedItemsPage: page }) => ({ default: page }))
);
const DirectoryPage = lazy(() =>
  import("./features/directory/DirectoryPage").then(({ DirectoryPage: page }) => ({ default: page }))
);
const FilesPage = lazy(() =>
  import("./features/files/FilesPage").then(({ FilesPage: page }) => ({ default: page }))
);
const DocumentsPage = lazy(() => import("./features/documents/DocumentsPage").then(({ DocumentsPage: page }) => ({ default: page })));
const ContentPage = lazy(() => import("./features/content/ContentPage").then(({ ContentPage: page }) => ({ default: page })));

const WhiteboardPage = lazy(() =>
  import("./features/whiteboard/WhiteboardPage").then(({ WhiteboardPage: page }) => ({ default: page }))
);
const PrivateRoomsPage = lazy(() => import("./features/private-rooms/PrivateRoomsPage").then(({ PrivateRoomsPage: page }) => ({ default: page })));
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
        <RouterHistoryProvider trackBrowserIndex>
          <DesktopThemeSync />
          <RouteRecoveryBoundary><PublicDesktopShell><ApplicationRoutes /></PublicDesktopShell></RouteRecoveryBoundary>
        </RouterHistoryProvider>
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
  if (normalizedPathname === "/sign-in/oidc-callback") {
    return <><RouteOrientation authenticated={false} /><OidcCallback /></>;
  }
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
  const setupValues = new URLSearchParams(location.search).getAll("setup");
  const workspaceSetupEntry =
    normalizedPathname === "/app" &&
    setupValues.length === 1 && setupValues[0] === "workspace";
  const signInTarget = authenticationGatewayTarget(location.search, location.hash, invitationEntry, workspaceSetupEntry);

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
              to={signInTarget}
              state={{ returnTo: safeMemberReturnTarget(`${location.pathname}${location.search}${location.hash}`) || "/app/" }}
              replace
            />
          }
        />
        <Route path="*" element={<Navigate to={signInTarget} state={{ returnTo: safeMemberReturnTarget(`${location.pathname}${location.search}${location.hash}`) || "/app/" }} replace />} />
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
                <Route path="/app/meetings" element={<MeetingsPage />} />
                <Route path="/app/artifacts" element={<MeetingArtifactsPage />} />
                <Route path="/app/saved" element={<SavedItemsPage />} />
                <Route path="/app/calls/phone" element={<PhonePage />} />
                <Route path="/app/directory" element={<DirectoryPage />} />
                <Route path="/app/files" element={<FilesPage />} />
                <Route path="/app/content" element={<ContentPage />} />
                <Route path="/app/whiteboard" element={<WhiteboardPage />} />
                <Route path="/app/documents" element={<DocumentsPage />} />
                <Route path="/app/private" element={<PrivateRoomsPage />} />
                <Route path="/app/you" element={<YouPage />} />
                <Route path="/app/settings" element={<Navigate to={`/app/you${location.search}${location.hash}`} replace />} />
                <Route path="/admin" element={<AdminPage />} />
                <Route path="/ops" element={<OpsPage />} />
              </Route>
              <Route
                path="/sign-in"
                element={
                  <Navigate
                    to={memberAppTarget(location.search, location.state)}
                    state={guestContinuationState(location.state)}
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

function authenticationGatewayTarget(search: string, hash: string, invitationEntry: boolean, workspaceSetup: boolean): string {
  const sourceSearch = new URLSearchParams(search);
  const sourceHash = new URLSearchParams(hash.replace(/^#/, ""));
  const safeSearch = new URLSearchParams();
  const safeHash = new URLSearchParams();
  if (invitationEntry) {
    for (const name of ["invitation_token", "tenant_slug"]) {
      const queryValue = sourceSearch.get(name);
      const fragmentValue = sourceHash.get(name);
      if (queryValue !== null) safeSearch.set(name, queryValue);
      if (fragmentValue !== null) safeHash.set(name, fragmentValue);
    }
  } else {
    const tenantSlug = sourceHash.get("tenant_slug") || sourceSearch.get("tenant_slug") || "";
    if (validWorkspaceSlug(tenantSlug)) safeSearch.set("tenant_slug", tenantSlug);
  }
  if (workspaceSetup) safeSearch.set("setup", "workspace");
  return `/sign-in${safeSearch.size ? `?${safeSearch}` : ""}${safeHash.size ? `#${safeHash}` : ""}`;
}

export function memberAppTarget(search: string, state?: unknown): string {
  return authenticationReturnTarget(search, state);
}

function RouteLoading() {
  return (
    <main className="route-loading" id="main-content" aria-busy="true">
      <span className="spinner" aria-hidden="true" />
      <h1>Loading K-Comms…</h1>
    </main>
  );
}
