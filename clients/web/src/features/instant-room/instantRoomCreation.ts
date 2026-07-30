import type { ApiClient } from "../../api";
import { ApiError } from "../../api";
import type { InstantRoomResult } from "../../types";
import { beginNewInstantRoomVisit } from "./idempotency";

const creationFlights = new Map<string, Promise<InstantRoomResult>>();

export async function createInstantRoomOnce(
  api: ApiClient,
  idempotencyKey: string,
  input: {
    display_name?: string;
    title?: string;
    device?: { name: string; platform: "web" };
  }
): Promise<InstantRoomResult> {
  const existing = creationFlights.get(idempotencyKey);
  if (existing) return existing;

  const request = createWithOneRetry(api, idempotencyKey, input).catch(
    (reason: unknown) => {
      creationFlights.delete(idempotencyKey);
      throw reason;
    }
  );
  creationFlights.set(idempotencyKey, request);
  return request;
}

async function createWithOneRetry(
  api: ApiClient,
  idempotencyKey: string,
  input: {
    display_name?: string;
    title?: string;
    device?: { name: string; platform: "web" };
  }
): Promise<InstantRoomResult> {
  try {
    return await api.createInstantRoom(input, idempotencyKey);
  } catch (reason: unknown) {
    if (
      reason instanceof ApiError &&
      reason.status === 409 &&
      reason.code === "idempotency_replay_expired"
    ) {
      const rotatedKey = beginNewInstantRoomVisit();
      const rotatedRequest = api.createInstantRoom(input, rotatedKey);
      creationFlights.set(rotatedKey, rotatedRequest);
      return rotatedRequest;
    }
    if (!isTransientCreateFailure(reason)) throw reason;
    await wait(350);
    return api.createInstantRoom(input, idempotencyKey);
  }
}

function isTransientCreateFailure(reason: unknown): boolean {
  return (
    (reason instanceof ApiError && reason.status >= 500) ||
    reason instanceof TypeError
  );
}

export function isDefinitiveRoomUnavailable(reason: unknown): boolean {
  return (
    reason instanceof ApiError &&
    [401, 403, 404, 410].includes(reason.status)
  );
}

function wait(milliseconds: number): Promise<void> {
  return new Promise((resolve) => window.setTimeout(resolve, milliseconds));
}
