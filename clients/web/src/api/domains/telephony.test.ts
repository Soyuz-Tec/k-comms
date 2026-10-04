import { describe, expect, it, vi } from "vitest";
import type { ApiRequest } from "../contracts";
import { createTelephonyApi } from "./telephony";

describe("telephony API boundary", () => {
  it("unwraps administrator assignments from configuration and rejects an empty save result", async () => {
    const number = { id: "line-1", phone_number: "+14155550123", extension: "101", user_id: "user-1", inbound_trunk_id: "ST_in", outbound_trunk_id: "ST_out" };
    const configuration = { enabled: false, configured: false, provider_ready: false, line_assigned: true, provider: "livekit_sip", number, can_manage: true };
    const request = vi.fn().mockResolvedValue({ data: configuration });
    const api = createTelephonyApi(request as ApiRequest);
    expect(await api.phoneAdminConfiguration()).toEqual(configuration);
    expect(await api.phoneNumberAssignment()).toEqual(number);
    const input = { phone_number: number.phone_number, extension: number.extension, user_id: number.user_id, inbound_trunk_id: number.inbound_trunk_id, outbound_trunk_id: number.outbound_trunk_id, reason: "Initial pilot" };
    expect(await api.updatePhoneNumber(input)).toEqual(number);
    expect(request).toHaveBeenLastCalledWith("/api/v1/admin/telephony", { method: "PUT", body: JSON.stringify(input) });
    request.mockResolvedValueOnce({ data: { ...configuration, number: null } });
    await expect(api.updatePhoneNumber(input)).rejects.toThrow("The saved phone assignment was not returned");
    request.mockResolvedValueOnce({ data: { ...configuration, number: null } });
    expect(await api.phoneNumberAssignment()).toBeNull();
  });

  it("preserves the idempotency key and encodes call identifiers on answer and join", async () => {
    const request = vi.fn().mockResolvedValue({ data: {} });
    const api = createTelephonyApi(request as ApiRequest);
    await api.dialPhone("+14155550123", "fixed-command-key");
    expect(request).toHaveBeenLastCalledWith("/api/v1/telephony/calls", { method: "POST", body: JSON.stringify({ destination: "+14155550123", idempotency_key: "fixed-command-key" }) });
    await api.answerPhoneCall("call/with?path");
    expect(request).toHaveBeenLastCalledWith("/api/v1/telephony/calls/call%2Fwith%3Fpath/answer", { method: "POST" });
    await api.joinPhoneCall("call/with?path");
    expect(request).toHaveBeenLastCalledWith("/api/v1/telephony/calls/call%2Fwith%3Fpath/join", { method: "POST" });
    await api.phoneCalls({ scope: "active", cursor: "cursor&next" });
    expect(request).toHaveBeenLastCalledWith("/api/v1/telephony/calls?limit=30&scope=active&cursor=cursor%26next");
  });
});
