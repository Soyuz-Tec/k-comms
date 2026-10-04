import { describe, expect, it } from "vitest";
import { phoneNumberInputError, phoneReadiness } from "./types";
import type { PhoneConfiguration, PhoneNumberInput } from "./types";

const number = { id: "line-1", phone_number: "+14155550123", extension: "101", user_id: "user-1" };
const configuration: PhoneConfiguration = { enabled: true, configured: false, provider: "livekit_sip", provider_ready: true, line_assigned: false, number: null, can_manage: false };
const validInput: PhoneNumberInput = { phone_number: number.phone_number, extension: "101", user_id: number.user_id, inbound_trunk_id: "ST_in", outbound_trunk_id: "ST_out", reason: "Assign pilot phone line" };

describe("phone readiness and setup boundaries", () => {
  it("does not mistake an unassigned line for missing provider configuration", () => {
    expect(phoneReadiness(configuration)).toMatchObject({ state: "unassigned", providerReady: true, lineAssigned: false, canCall: false });
    expect(phoneReadiness({ ...configuration, enabled: false })).toMatchObject({ state: "disabled", canCall: false });
  });

  it("keeps calling conservatively gated when reading an older server response", () => {
    const legacy: PhoneConfiguration = { enabled: true, configured: true, number, provider: "livekit_sip", can_manage: false };
    expect(phoneReadiness(legacy).canCall).toBe(true);
    expect(phoneReadiness({ ...legacy, configured: false }).canCall).toBe(false);
    expect(phoneReadiness({ ...legacy, number: null }).canCall).toBe(false);
  });

  it("allows exact trunk IDs and refuses an ineligible member or malformed dial number", () => {
    expect(phoneNumberInputError(validInput, [number.user_id])).toBeNull();
    expect(phoneNumberInputError({ ...validInput, user_id: "service-1" }, [number.user_id])).toMatch(/active workspace member/);
    expect(phoneNumberInputError({ ...validInput, phone_number: "4155550123" }, [number.user_id])).toMatch(/international phone number/);
    expect(phoneNumberInputError({ ...validInput, extension: "1" }, [number.user_id])).toMatch(/2–8 digits/);
  });

  it("enforces the server audit-reason byte bound for multibyte text", () => {
    expect(phoneNumberInputError({ ...validInput, reason: "😀".repeat(125) }, [number.user_id])).toBeNull();
    expect(phoneNumberInputError({ ...validInput, reason: "😀".repeat(126) }, [number.user_id])).toMatch(/audit record/);
  });
});
