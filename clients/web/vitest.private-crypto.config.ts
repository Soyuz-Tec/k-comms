import { defineConfig } from "vitest/config";
export default defineConfig({ test: { environment: "node", include: ["src/features/private-rooms/MatrixPrivateClient.crypto.test.ts", "src/features/private-rooms/MatrixPrivateClient.epoch.crypto.test.ts"], maxWorkers: 1 } });
