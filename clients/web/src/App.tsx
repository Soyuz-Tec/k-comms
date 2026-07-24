import { lazy, Suspense } from "react";
import { BrowserRouter, Navigate, Route, Routes } from "react-router-dom";
import { ProductShell } from "./app/ProductShell";
import { RouteOrientation } from "./app/RouteOrientation";
import { SessionProvider, useSession } from "./app/session";
import { WorkspaceDataProvider } from "./app/workspace-data";
import { StepUpProvider } from "./app/step-up";
import { AuthScreen } from "./features/auth/AuthScreen";
import { ForgotPasswordPage, ResetPasswordPage } from "./features/auth/PasswordRecoveryPages";
import "./mobile-experience.css";

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
  const { session } = useSession();
  if (!session) {
    return (
      <Routes>
        <Route path="/forgot-password" element={<><RouteOrientation authenticated={false} /><ForgotPasswordPage /></>} />
        <Route path="/reset-password" element={<><RouteOrientation authenticated={false} /><ResetPasswordPage /></>} />
        <Route path="*" element={<AuthScreen />} />
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
                <Route path="/app" element={<ChatPage />} />
                <Route path="/app/calls" element={<CallsPage />} />
                <Route path="/app/directory" element={<DirectoryPage />} />
                <Route path="/app/files" element={<FilesPage />} />
                <Route path="/app/you" element={<YouPage />} />
                <Route path="/app/settings" element={<Navigate to="/app/you" replace />} />
                <Route path="/admin" element={<AdminPage />} />
                <Route path="/ops" element={<OpsPage />} />
              </Route>
              <Route path="*" element={<Navigate to="/app" replace />} />
            </Routes>
          </Suspense>
        </StepUpProvider>
      </WorkspaceDataProvider>
    </>
  );
}

function RouteLoading() {
  return (
    <main className="route-loading" id="main-content" aria-busy="true">
      <span className="spinner" aria-hidden="true" />
      <h1>Loading K-Comms…</h1>
    </main>
  );
}
