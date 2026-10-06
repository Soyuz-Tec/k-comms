import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import App, { createAppRouter } from "./App";
import { initializeDesktopSessionStorage } from "./desktop/session";
import { verifyDesktopRestoredSession } from "./desktop/restore";
import { DesktopBoundary, DesktopUnavailable } from "./desktop/DesktopBoundary";
import { PwaProvider, ensurePwaRegistration } from "./pwa";

const root = document.getElementById("root");
if (!root) throw new Error("Application root is missing");

const applicationRoot = createRoot(root);
void initializeDesktopSessionStorage().then(verifyDesktopRestoredSession).then(() => {
  void ensurePwaRegistration();
  // The browser history listener belongs to the application lifetime, outside StrictMode.
  const router = createAppRouter();
  applicationRoot.render(
    <StrictMode>
      <DesktopBoundary>
        <PwaProvider><App router={router} /></PwaProvider>
      </DesktopBoundary>
    </StrictMode>
  );
}).catch(() => applicationRoot.render(<DesktopUnavailable />));
