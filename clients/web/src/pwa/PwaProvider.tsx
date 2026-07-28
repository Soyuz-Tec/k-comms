import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useRef,
  useState
} from "react";
import type { ReactNode } from "react";
import {
  activateWaitingWorker,
  ensurePwaRegistration,
  supportsPwaRegistration
} from "./registration";

export type PwaInstallMode =
  | "native-prompt"
  | "manual-ios"
  | "manual-browser"
  | "installed"
  | "unavailable";

export type PwaInstallResult =
  | "accepted"
  | "dismissed"
  | "manual-ios"
  | "manual-browser"
  | "unavailable";

export type PwaContextValue = {
  installMode: PwaInstallMode;
  updateAvailable: boolean;
  requestInstall: () => Promise<PwaInstallResult>;
  applyUpdate: () => void;
  dismissUpdate: () => void;
};

type BeforeInstallPromptEvent = Event & {
  prompt: () => Promise<void>;
  userChoice: Promise<{ outcome: "accepted" | "dismissed"; platform: string }>;
};

const UPDATE_INTERVAL_MS = 30 * 60 * 1000;

const PwaContext = createContext<PwaContextValue | null>(null);

export function PwaProvider({ children }: { children: ReactNode }) {
  const [installMode, setInstallMode] = useState<PwaInstallMode>(
    currentInstallMode
  );
  const [updateAvailable, setUpdateAvailable] = useState(false);
  const promptRef = useRef<BeforeInstallPromptEvent | null>(null);
  const registrationRef = useRef<ServiceWorkerRegistration | null>(null);
  const dismissedWorkerRef = useRef<ServiceWorker | null>(null);

  useEffect(() => {
    const displayMode = window.matchMedia?.("(display-mode: standalone)");

    const refreshInstalledState = () => {
      if (isStandalone()) setInstallMode("installed");
    };
    const captureInstallPrompt = (event: Event) => {
      const promptEvent = event as BeforeInstallPromptEvent;
      promptEvent.preventDefault();
      promptRef.current = promptEvent;
      setInstallMode("native-prompt");
    };
    const markInstalled = () => {
      promptRef.current = null;
      setInstallMode("installed");
    };

    window.addEventListener(
      "beforeinstallprompt",
      captureInstallPrompt as EventListener
    );
    window.addEventListener("appinstalled", markInstalled);
    displayMode?.addEventListener?.("change", refreshInstalledState);

    return () => {
      window.removeEventListener(
        "beforeinstallprompt",
        captureInstallPrompt as EventListener
      );
      window.removeEventListener("appinstalled", markInstalled);
      displayMode?.removeEventListener?.("change", refreshInstalledState);
    };
  }, []);

  useEffect(() => {
    let current = true;
    let registrationInFlight = false;
    let updateInFlight = false;
    const observedWorkers = new Set<ServiceWorker>();
    let observedRegistration: ServiceWorkerRegistration | null = null;
    let updateFoundHandler: (() => void) | null = null;

    const detectWaitingWorker = () => {
      const waiting = registrationRef.current?.waiting;
      if (!current || !waiting || waiting === dismissedWorkerRef.current) return;
      setUpdateAvailable(true);
    };

    const observeWorker = (worker: ServiceWorker | null) => {
      if (!worker || observedWorkers.has(worker)) return;
      observedWorkers.add(worker);
      worker.addEventListener("statechange", detectWaitingWorker);
    };

    const observeRegistration = (registration: ServiceWorkerRegistration) => {
      registrationRef.current = registration;
      observedRegistration = registration;
      detectWaitingWorker();
      observeWorker(registration.installing);
      updateFoundHandler = () => {
        observeWorker(registration.installing);
        detectWaitingWorker();
      };
      registration.addEventListener("updatefound", updateFoundHandler);
    };

    const connectRegistration = () => {
      if (registrationRef.current || registrationInFlight) return;

      registrationInFlight = true;
      void ensurePwaRegistration()
        .then((registration) => {
          if (!current) return;
          if (!registration) {
            setInstallMode("unavailable");
            return;
          }

          observeRegistration(registration);
          setInstallMode((mode) => {
            if (mode === "installed") return mode;
            return promptRef.current ? "native-prompt" : fallbackInstallMode();
          });
        })
        .finally(() => {
          registrationInFlight = false;
        });
    };

    const recheckForUpdate = () => {
      const registration = registrationRef.current;
      if (!registration) {
        connectRegistration();
        return;
      }
      if (
        updateInFlight ||
        document.visibilityState === "hidden" ||
        navigator.onLine === false
      ) {
        return;
      }

      updateInFlight = true;
      void registration
        .update()
        .catch(() => undefined)
        .finally(() => {
          updateInFlight = false;
          detectWaitingWorker();
        });
    };

    connectRegistration();

    const handleVisibility = () => {
      if (document.visibilityState === "visible") recheckForUpdate();
    };
    window.addEventListener("online", recheckForUpdate);
    document.addEventListener("visibilitychange", handleVisibility);
    const updateInterval = window.setInterval(
      recheckForUpdate,
      UPDATE_INTERVAL_MS
    );

    return () => {
      current = false;
      window.removeEventListener("online", recheckForUpdate);
      document.removeEventListener("visibilitychange", handleVisibility);
      window.clearInterval(updateInterval);
      for (const worker of observedWorkers) {
        worker.removeEventListener("statechange", detectWaitingWorker);
      }
      if (observedRegistration && updateFoundHandler) {
        observedRegistration.removeEventListener(
          "updatefound",
          updateFoundHandler
        );
      }
    };
  }, []);

  const requestInstall = useCallback(async (): Promise<PwaInstallResult> => {
    if (isStandalone()) {
      setInstallMode("installed");
      return "unavailable";
    }

    const promptEvent = promptRef.current;
    if (promptEvent) {
      promptRef.current = null;
      try {
        await promptEvent.prompt();
        const choice = await promptEvent.userChoice;
        if (choice.outcome === "accepted") {
          setInstallMode("installed");
          return "accepted";
        }
        setInstallMode(fallbackInstallMode());
        return "dismissed";
      } catch {
        const fallback = fallbackInstallMode();
        setInstallMode(fallback);
        return fallback;
      }
    }

    const fallback = fallbackInstallMode();
    setInstallMode(fallback);
    return fallback;
  }, []);

  const applyUpdate = useCallback(() => {
    const registration = registrationRef.current;
    if (!registration) return;
    setUpdateAvailable(false);
    activateWaitingWorker(registration);
  }, []);

  const dismissUpdate = useCallback(() => {
    dismissedWorkerRef.current = registrationRef.current?.waiting || null;
    setUpdateAvailable(false);
  }, []);

  return (
    <PwaContext.Provider
      value={{
        installMode,
        updateAvailable,
        requestInstall,
        applyUpdate,
        dismissUpdate
      }}
    >
      {children}
    </PwaContext.Provider>
  );
}

export function usePwa(): PwaContextValue {
  const context = useContext(PwaContext);
  if (!context) throw new Error("usePwa must be used within PwaProvider");
  return context;
}

function currentInstallMode(): PwaInstallMode {
  if (typeof window === "undefined") return "unavailable";
  if (isStandalone()) return "installed";
  return fallbackInstallMode();
}

function fallbackInstallMode(): "manual-ios" | "manual-browser" | "unavailable" {
  if (!supportsPwaRegistration()) return "unavailable";
  return isIosBrowser() ? "manual-ios" : "manual-browser";
}

function isStandalone(): boolean {
  if (typeof window === "undefined" || typeof navigator === "undefined") {
    return false;
  }
  const iosNavigator = navigator as Navigator & { standalone?: boolean };
  return (
    window.matchMedia?.("(display-mode: standalone)").matches === true ||
    iosNavigator.standalone === true
  );
}

function isIosBrowser(): boolean {
  if (typeof navigator === "undefined") return false;
  return (
    /iPad|iPhone|iPod/.test(navigator.userAgent) ||
    (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1)
  );
}
