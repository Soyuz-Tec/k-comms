import { AppIcon } from "../../components/AppIcon";
import {
  CALL_READINESS_DURATION_SECONDS,
  downloadCallReadinessReport,
  type CallReadinessCheckResult
} from "./callReadiness";
import type { CallReadinessPhase, CallReadinessTestState } from "./useCallReadinessTest";
import "./CallReadinessPanel.css";

function phaseLabel(phase: CallReadinessPhase): string {
  if (phase === "preflight") return "Checking this browser and network";
  if (phase === "switching_transport") return "Switching to TURN over TLS";
  if (phase === "waiting_for_peer") return "Waiting for the UAE office";
  if (phase === "measuring") return "Measuring the live conversation";
  if (phase === "complete") return "Test complete";
  if (phase === "failed") return "Test could not complete";
  return "Ready to begin";
}

function checkIcon(status: CallReadinessCheckResult["status"]) {
  if (status === "passed") return <AppIcon name="check" />;
  if (status === "failed" || status === "skipped") return <AppIcon name="triangleAlert" />;
  if (status === "running") return <AppIcon className="spin" name="loader" />;
  return <AppIcon name="circle" />;
}

function metric(value: number | null, suffix: string): string {
  return value === null ? "Pending" : `${value}${suffix}`;
}

export function CallReadinessPanel({ readiness }: { readiness: CallReadinessTestState }) {
  const elapsed = CALL_READINESS_DURATION_SECONDS - readiness.secondsRemaining;
  const final = readiness.phase === "complete" || readiness.phase === "failed";
  const verdict = readiness.evaluation.verdict;
  const tlsStatus = readiness.tlsRelaySwitchSucceeded
    ? "passed"
    : final
      ? "failed"
      : readiness.phase === "switching_transport"
        ? "running"
        : "pending";

  return (
    <aside className={`call-readiness-panel verdict-${verdict}`} aria-labelledby="call-readiness-title">
      <header>
        <span className="call-readiness-icon" aria-hidden="true"><AppIcon name="lock" /></span>
        <div>
          <span className="eyebrow">UAE office call test</span>
          <h3 id="call-readiness-title">{phaseLabel(readiness.phase)}</h3>
        </div>
      </header>

      {readiness.phase === "measuring" && (
        <div className="call-readiness-progress" role="status" aria-live="polite">
          <div><strong>{readiness.secondsRemaining}s</strong><span>remaining</span></div>
          <progress max={CALL_READINESS_DURATION_SECONDS} value={elapsed}>
            {elapsed} of {CALL_READINESS_DURATION_SECONDS} seconds
          </progress>
        </div>
      )}

      {readiness.phase === "waiting_for_peer" && (
        <p className="call-readiness-guidance" role="status">
          Ask someone in the UAE office to open the invite and join with their microphone. Measurement starts automatically when both sides are ready.
        </p>
      )}

      <ul className="call-readiness-checks" aria-label="Connection checks">
        {readiness.checks.map((check) => (
          <li className={`status-${check.status}`} key={check.id}>
            <span aria-hidden="true">{checkIcon(check.status)}</span>
            <span>{check.label}</span>
            <small>{check.status}</small>
          </li>
        ))}
        <li className={`status-${tlsStatus}`}>
          <span aria-hidden="true">{readiness.tlsRelaySwitchSucceeded ? <AppIcon name="check" /> : final ? <AppIcon name="triangleAlert" /> : <AppIcon name="circle" />}</span>
          <span>TURN/TLS path</span>
          <small>{tlsStatus}</small>
        </li>
      </ul>

      {readiness.metrics && (
        <dl className="call-readiness-metrics">
          <div><dt>Media region</dt><dd>{readiness.metrics.region || "Not reported"}</dd></div>
          <div><dt>Transport</dt><dd>{readiness.metrics.transport}</dd></div>
          <div><dt>Round trip</dt><dd>{metric(readiness.metrics.round_trip_time_ms, " ms")}</dd></div>
          <div><dt>Jitter</dt><dd>{metric(readiness.metrics.jitter_ms, " ms")}</dd></div>
          <div><dt>Packet loss</dt><dd>{metric(readiness.metrics.packet_loss_percent, "%")}</dd></div>
          <div><dt>Codec</dt><dd>{readiness.metrics.codec || "Pending"}</dd></div>
        </dl>
      )}

      {(readiness.phase === "measuring" || final) && (
        <button
          className={`button call-readiness-heard ${readiness.heardPeer ? "primary" : "ghost"}`}
          type="button"
          aria-pressed={readiness.heardPeer}
          onClick={() => readiness.setHeardPeer(!readiness.heardPeer)}
        >
          <AppIcon name={readiness.heardPeer ? "check" : "phone"} />
          {readiness.heardPeer ? "Office audio confirmed" : "I can hear the office"}
        </button>
      )}

      {final && (
        <section className="call-readiness-result" aria-live="polite">
          <strong>{verdict === "pass" ? "Ready" : verdict === "warning" ? "Ready with warnings" : verdict === "fail" ? "Not ready" : "Finalizing results…"}</strong>
          {readiness.failure && <p>{readiness.failure}</p>}
          {readiness.evaluation.reasons.length > 0 && (
            <ul>{readiness.evaluation.reasons.map((reason) => <li key={reason}>{reason}</li>)}</ul>
          )}
          <button
            className="button ghost compact"
            type="button"
            disabled={!readiness.report}
            onClick={() => readiness.report && downloadCallReadinessReport(readiness.report)}
          >
            <AppIcon name="download" /> Download privacy-safe report
          </button>
        </section>
      )}

      <p className="call-readiness-privacy">
        No audio is recorded. The report excludes names, room IDs, credentials, and network addresses.
      </p>
    </aside>
  );
}
