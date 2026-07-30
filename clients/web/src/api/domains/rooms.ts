import type { DataResponse, GuestLink, InstantRoomPreview, InstantRoomResult, ListResponse } from "../../types";
import type { ApiRequest } from "../contracts";

interface RoomsApiSupport {
  normalizeInstantRoomPreview: (value: unknown) => InstantRoomPreview;
  normalizeInstantRoomResult: (value: unknown) => InstantRoomResult;
  unwrapUnknownData: (payload: unknown) => unknown;
  operationId: () => string;
}

export function createRoomsApi(
  request: ApiRequest,
  {
    normalizeInstantRoomPreview,
    normalizeInstantRoomResult,
    operationId,
    unwrapUnknownData
  }: RoomsApiSupport
) {
  const api = {
    createInstantRoom(
        input: {
          display_name?: string;
          title?: string;
          device?: { name: string; platform: "web" };
        },
        idempotencyKey: string
      ): Promise<InstantRoomResult> {
        return request<unknown>("/api/v1/instant-rooms", {
          method: "POST",
          headers: { "Idempotency-Key": idempotencyKey },
          body: JSON.stringify(input)
        }).then(normalizeInstantRoomResult);
      },

    previewInstantRoom(token: string): Promise<InstantRoomPreview> {
        return request<unknown>(
          "/api/v1/instant-rooms/preview",
          {
            method: "POST",
            body: JSON.stringify({ token }),
            retryAuthentication: false,
            skipAuthentication: true
          }
        ).then((payload) => normalizeInstantRoomPreview(unwrapUnknownData(payload)));
      },

    joinInstantRoom(input: {
        token: string;
        display_name?: string;
        device?: { name: string; platform: "web" };
      }, idempotencyKey: string): Promise<InstantRoomResult> {
        return request<unknown>("/api/v1/instant-room-sessions", {
          method: "POST",
          headers: { "Idempotency-Key": idempotencyKey },
          body: JSON.stringify(input)
        }).then(normalizeInstantRoomResult);
      },

    createGuestLink(
        conversationId: string,
        input: {
          expires_in_seconds: number;
          max_uses: number;
          conversion_email?: string;
        }
      ): Promise<{
        guestLink: GuestLink;
        token: string;
        url: string;
        conversionVerificationCode?: string;
      }> {
        return request<{
          data?: GuestLink;
          guest_link?: GuestLink;
          token?: string;
          guest_link_token?: string;
          conversion_verification_code?: string;
        }>(`/api/v1/conversations/${encodeURIComponent(conversationId)}/guest-links`, {
          method: "POST",
          headers: { "Idempotency-Key": operationId() },
          body: JSON.stringify(input)
        }).then((response) => {
          const guestLink = response.data || response.guest_link;
          const token = response.token || response.guest_link_token;
          const conversionVerificationCode = response.conversion_verification_code;
          const conversionRequested = Boolean(input.conversion_email);
          const validConversionCode =
            typeof conversionVerificationCode === "string" &&
            /^[A-Za-z0-9_-]{43}$/.test(conversionVerificationCode);
          if (
            !guestLink ||
            !token ||
            !guestLink.share_url ||
            (conversionRequested && !validConversionCode) ||
            (!conversionRequested && conversionVerificationCode !== undefined)
          ) {
            throw new Error("The server did not return a complete guest link.");
          }
          return {
            guestLink,
            token,
            url: guestLink.share_url,
            ...(validConversionCode
              ? { conversionVerificationCode }
              : {})
          };
        });
      },

    guestLinks(conversationId: string): Promise<GuestLink[]> {
        return request<ListResponse<GuestLink>>(
          `/api/v1/conversations/${encodeURIComponent(conversationId)}/guest-links`
        ).then((response) => response.data);
      },

    revokeGuestLink(
        conversationId: string,
        guestLinkId: string
      ): Promise<GuestLink> {
        return request<DataResponse<GuestLink>>(
          `/api/v1/conversations/${encodeURIComponent(conversationId)}/guest-links/${encodeURIComponent(guestLinkId)}`,
          { method: "DELETE" }
        ).then((response) => response.data);
      }
  };
  return api;
}

export type RoomsApi = ReturnType<typeof createRoomsApi>;
