import type { DataResponse } from "../../types";
import type { FederationMetadataExport, FederationPolicyInput, FederationRoom, FederationTimeline, FederationTrust } from "../../types/federation";
import type { ApiRequest } from "../contracts";
const roomPath = (id: string) => `/api/v1/conversations/${encodeURIComponent(id)}/federation`;
export function createFederationApi(request: ApiRequest) {
  const data = <T>(path: string, method = "GET", body?: unknown) => request<DataResponse<T>>(path, { method, body: body === undefined ? undefined : JSON.stringify(body) }).then(response => response.data);
  return {
    federationTrusts: () => data<FederationTrust[]>("/api/v1/admin/federation/trusts"),
    putFederationTrust: (input: FederationPolicyInput) => data<FederationTrust>("/api/v1/admin/federation/trusts", "PUT", input),
    federationRoom: (id: string) => data<FederationRoom | null>(roomPath(id)),
    createFederationRoom: (id: string, domain: string) => data<FederationRoom>(roomPath(id), "POST", { domain, plaintext_disclosure_accepted: true }),
    federationConsent: (id: string, version: number, accept: boolean) => data<FederationRoom>(`${roomPath(id)}/consent`, "PUT", { version, accept, plaintext_disclosure_accepted: accept }),
    inviteFederationParticipant: (id: string, version: number, matrix_user_id: string) => data<FederationRoom>(`${roomPath(id)}/invitations`, "POST", { version, matrix_user_id }),
    sendFederationMessage: (id: string, version: number, body: string, idempotency_key: string) => data<{ id: string; status: string; disclosure: "plaintext_bridge" }>(`${roomPath(id)}/messages`, "POST", { version, body, idempotency_key }),
    federationTimeline: (id: string, cursor?: string) => data<FederationTimeline>(`${roomPath(id)}/messages${cursor ? `?cursor=${encodeURIComponent(cursor)}` : ""}`),
    exportFederationMetadata: (id: string) => data<FederationMetadataExport>(`${roomPath(id)}/export`),
    closeFederationRoom: (id: string, version: number) => data<FederationRoom>(roomPath(id), "DELETE", { version })
  };
}
export type FederationApi = ReturnType<typeof createFederationApi>;
