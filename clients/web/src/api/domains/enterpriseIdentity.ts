import type { DataResponse, Session } from "../../types";
import type { ApiRequest, LoginInput } from "../contracts";
import type { Availability, IdentitySecurity, LoginResult, MfaEnrollment, RecoveryCodes, UpdateAvailability } from "../../types/enterpriseIdentity";

export function createEnterpriseIdentityApi(request: ApiRequest, withReceivedAt: <T extends Session>(session: T) => T) {
  return {
    passwordSignIn(input: LoginInput): Promise<LoginResult> {
      return request<LoginResult>("/api/v1/sessions", { method: "POST", body: JSON.stringify(input), retryAuthentication: false, skipAuthentication: true }).then((result) => "mfa_required" in result ? result : withReceivedAt(result));
    },
    completeMfaSignIn(challengeToken: string, code: string): Promise<Session> {
      return request<Session>("/api/v1/auth/mfa", { method: "POST", body: JSON.stringify({ challenge_token: challengeToken, code }), retryAuthentication: false, skipAuthentication: true }).then(withReceivedAt);
    },
    startOidc(tenantSlug: string, returnTo: string): Promise<{ authorization_url: string }> {
      return request("/api/v1/auth/oidc/start", { credentials: "include", method: "POST", body: JSON.stringify({ tenant_slug: tenantSlug, return_to: returnTo }), retryAuthentication: false, skipAuthentication: true });
    },
    completeOidc(code: string, state: string): Promise<{ session: Session; return_to: string }> {
      return request<{ session: Session; return_to: string }>("/api/v1/auth/oidc/callback", { credentials: "include", method: "POST", body: JSON.stringify({ code, state }), retryAuthentication: false, skipAuthentication: true }).then((response) => ({ ...response, session: withReceivedAt(response.session) }));
    },
    stepUpOidc(tenantSlug: string): Promise<{ authorization_url: string }> {
      return request("/api/v1/me/oidc/step-up/start", { credentials: "include", method: "POST", body: JSON.stringify({ tenant_slug: tenantSlug, return_to: "/app/settings?section=security" }) });
    },
    linkOidc(tenantSlug: string): Promise<{ authorization_url: string }> {
      return request("/api/v1/me/oidc/link/start", { credentials: "include", method: "POST", body: JSON.stringify({ tenant_slug: tenantSlug, return_to: "/app/settings?section=security" }) });
    },
    completeOidcLink(code: string, state: string): Promise<{ linked: true; return_to: string }> {
      return request("/api/v1/me/oidc/link/callback", { credentials: "include", method: "POST", body: JSON.stringify({ code, state }) });
    },
    identitySecurity(): Promise<IdentitySecurity> {
      return request<DataResponse<IdentitySecurity>>("/api/v1/me/security").then((response) => response.data);
    },
    enrollMfa(): Promise<MfaEnrollment> {
      return request<DataResponse<MfaEnrollment>>("/api/v1/me/mfa/enroll", { method: "POST" }).then((response) => response.data);
    },
    confirmMfa(code: string): Promise<RecoveryCodes> {
      return request<DataResponse<RecoveryCodes>>("/api/v1/me/mfa/confirm", { method: "POST", body: JSON.stringify({ code }) }).then((response) => response.data);
    },
    disableMfa(code: string): Promise<void> {
      return request("/api/v1/me/mfa/disable", { method: "POST", body: JSON.stringify({ code }) });
    },
    rotateMfaRecovery(code: string): Promise<RecoveryCodes> {
      return request<DataResponse<RecoveryCodes>>("/api/v1/me/mfa/recovery-codes", { method: "POST", body: JSON.stringify({ code }) }).then((response) => response.data);
    },
    availability(): Promise<Availability> {
      return request<DataResponse<Availability>>("/api/v1/me/availability").then((response) => response.data);
    },
    updateAvailability(input: UpdateAvailability): Promise<Availability> {
      return request<DataResponse<Availability>>("/api/v1/me/availability", { method: "PUT", body: JSON.stringify(input) }).then((response) => response.data);
    },

  };
}
export type EnterpriseIdentityApi = ReturnType<typeof createEnterpriseIdentityApi>;
