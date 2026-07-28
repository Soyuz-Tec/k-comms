import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import App from "./App";
import { PwaProvider, ensurePwaRegistration } from "./pwa";

const root = document.getElementById("root");
if (!root) throw new Error("Application root is missing");

void ensurePwaRegistration();

createRoot(root).render(
  <StrictMode>
    <PwaProvider>
      <App />
    </PwaProvider>
  </StrictMode>
);
