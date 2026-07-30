import { useState } from "react";
import type { FormEvent } from "react";
import { errorText } from "../../lib/format";
import type {
  Conversation,
  GuestSession,
  Session,
  SocketHandoff
} from "../../types";
import type { ConversionReceipt } from "./GuestConversionPanel";
import type { GuestRoomApi } from "./roomApi";

interface UseGuestConversionOptions {
  api: GuestRoomApi;
  initialSession: GuestSession;
  accountActionsAllowed: boolean;
  handoffRealtime: (handoff?: SocketHandoff) => void;
  onConverted: (
    session: Session,
    conversation: Conversation,
    socketHandoff?: SocketHandoff
  ) => void;
  setError: (message: string) => void;
}

export function useGuestConversion({
  api,
  initialSession,
  accountActionsAllowed,
  handoffRealtime,
  onConverted,
  setError
}: UseGuestConversionOptions) {
  const [showAccount, setShowAccount] = useState(false);
  const [converting, setConverting] = useState(false);
  const [conversionNotice, setConversionNotice] = useState("");
  const [conversionReceipt, setConversionReceipt] =
    useState<ConversionReceipt | null>(null);
  const selfServiceConversion =
    initialSession.capabilities.self_service_conversion === true;
  const conversionEnabled =
    initialSession.capabilities.conversion_enabled === true ||
    selfServiceConversion;

  async function convertAccount(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!accountActionsAllowed) {
      setConversionNotice("");
      setError(
        "Account creation is disabled for this deployment address. Open K-Comms over trusted HTTPS before entering or submitting credentials."
      );
      return;
    }

    const values = new FormData(event.currentTarget);
    setConverting(true);
    setConversionNotice("");
    setError("");
    try {
      if (!api.convertAccount) {
        throw new Error(
          "Account creation is not available for this room session."
        );
      }
      const result = await api.convertAccount({
        email: String(values.get("email") || "").trim(),
        password: String(values.get("password") || ""),
        ...(selfServiceConversion
          ? {
              display_name:
                String(values.get("display_name") || "").trim() || undefined
            }
          : {
              verification_code: String(
                values.get("verification_code") || ""
              ).trim()
            })
      });
      if (selfServiceConversion) {
        handoffRealtime(result.socket_handoff);
        onConverted(
          result.session,
          result.conversation,
          result.socket_handoff
        );
        setShowAccount(false);
        setConversionNotice(
          `Account created for ${result.session.user.display_name}. You are still in this conversation.`
        );
        setConversionReceipt({
          displayName: result.session.user.display_name,
          workspaceSlug: result.session.tenant.slug
        });
      } else {
        onConverted(result.session, result.conversation);
      }
    } catch (reason: unknown) {
      setError(errorText(reason));
    } finally {
      setConverting(false);
    }
  }

  return {
    conversionEnabled,
    conversionNotice,
    conversionReceipt,
    converting,
    convertAccount,
    selfServiceConversion,
    setShowAccount,
    showAccount
  };
}
