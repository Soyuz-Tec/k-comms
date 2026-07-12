import { BrowserRouter, Navigate, Route, Routes } from "react-router-dom";
import { ProductShell } from "./app/ProductShell";
import { SessionProvider, useSession } from "./app/session";
import { WorkspaceDataProvider } from "./app/workspace-data";
import { StepUpProvider } from "./app/step-up";
import { AdminPage } from "./features/admin/AdminPage";
import { AuthScreen } from "./features/auth/AuthScreen";
import { ForgotPasswordPage, ResetPasswordPage } from "./features/auth/PasswordRecoveryPages";
import { ChatPage } from "./features/chat/ChatPage";
import { OpsPage } from "./features/ops/OpsPage";
import { SettingsPage } from "./features/settings/SettingsPage";

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
        <Route path="/forgot-password" element={<ForgotPasswordPage />} />
        <Route path="/reset-password" element={<ResetPasswordPage />} />
        <Route path="*" element={<AuthScreen />} />
      </Routes>
    );
  }

  return (
    <WorkspaceDataProvider>
      <StepUpProvider>
        <Routes>
          <Route element={<ProductShell />}>
            <Route path="/app" element={<ChatPage />} />
            <Route path="/app/settings" element={<SettingsPage />} />
            <Route path="/admin" element={<AdminPage />} />
            <Route path="/ops" element={<OpsPage />} />
          </Route>
          <Route path="*" element={<Navigate to="/app" replace />} />
        </Routes>
      </StepUpProvider>
    </WorkspaceDataProvider>
  );
}
