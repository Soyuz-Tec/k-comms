import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import App from "./App";
import { initializeDesktopSessionStorage } from "./desktop/session";
import { verifyDesktopRestoredSession } from "./desktop/restore";
import { DesktopBoundary, DesktopUnavailable } from "./desktop/DesktopBoundary";
import { PwaProvider, ensurePwaRegistration } from "./pwa";

const root = document.getElementById("root");
if (!root) throw new Error("Application root is missing");

const applicationRoot = createRoot(root);
void initializeDesktopSessionStorage().then(verifyDesktopRestoredSession).then(() => {
  void ensurePwaRegistration();
  applicationRoot.render(
    <StrictMode>
      <DesktopBoundary>
        <PwaProvider><App /></PwaProvider>
      </DesktopBoundary>
    </StrictMode>
  );
}).catch(() => applicationRoot.render(<DesktopUnavailable />));
