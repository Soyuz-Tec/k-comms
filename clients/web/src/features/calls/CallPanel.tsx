import { useEffect, type ReactNode } from "react";
import { createPortal } from "react-dom";
import { AppIcon } from "../../components/AppIcon";
import {
  AppMenuCloseButton,
  AppMenuTrigger,
  AppSurfaceControlButton
} from "../../components/AppMenuControls";
import {
  AudioParticipantStage,
  CallActions,
  CallPrejoinDialog,
  prioritizeVideoParticipants,
  VideoParticipantGrid
} from "./CallPanelViews";
import { useCallSession, type CallPanelProps } from "./useCallSession";
import { formatCallDuration, mediaLabel } from "./callMedia";
import { CallReadinessPanel } from "./CallReadinessPanel";
import { downloadCallReadinessReport } from "./callReadiness";

export type {
  CallApi,
  CallPanelSessionState,
  CallPhase
} from "./callContracts";
export { callPublishDefaults, callRtcConfig } from "./callMedia";

export const CALL_TERMINAL_NOTICE_TIMEOUT_MS = 8_000;

export function CallTerminalNotice({
  title,
  message,
  error = false,
  autoDismiss = false,
  action,
  onDismiss
}: {
  title: string;
  message: string;
  error?: boolean;
  autoDismiss?: boolean;
  action?: ReactNode;
  onDismiss: () => void;
}) {
  useEffect(() => {
    if (!autoDismiss) return;
    const timeout = window.setTimeout(
      onDismiss,
      CALL_TERMINAL_NOTICE_TIMEOUT_MS
    );
    return () => window.clearTimeout(timeout);
  }, [autoDismiss, message, onDismiss]);

  return (
    <div className={`audio-call-terminal-notice ${error ? "error" : ""}`} role={error ? "alert" : "status"}>
      <strong>{title}</strong>
      <span>{message}</span>
      {action}
      <button className="audio-call-terminal-notice-close" type="button" aria-label="Dismiss call notice" onClick={onDismiss}>
        <AppIcon name="x" />
      </button>
    </div>
  );
}

function initials(name: string): string {
  return name.trim().split(/\s+/).slice(0, 2)
    .map((part) => part[0]?.toUpperCase() || "")
    .join("") || "?";
}


export function CallPanel({
  api,
  conversation,
  audioEnabled,
  videoEnabled,
  currentUserDisplayName,
  currentUserId,
  realtimeEvent,
  showVideoAction = true,
  launchRequest,
  launchRequestId,
  launchReadinessMode,
  onLaunchRequestConsumed,
  renderActions = true,
  onNavigate,
  onOpenChat,
  onSessionStateChange
}: CallPanelProps) {
  const {
    accessRevoked,
    activeKind,
    audioBlocked,
    call,
    callControlLabelsVisible,
    callDockRef,
    callMenuTriggerRef,
    callWorkspaceRef,
    callWorkspaceTab,
    cameraEnabled,
    cameras,
    closeMobileCallMenu,
    currentMediaKind,
    dismissTerminalNotice,
    elapsedSeconds,
    enablePlayback,
    endConfirmationOpen,
    endConfirmationRef,
    endForEveryone,
    error,
    expandedCallModal,
    join,
    joined,
    joinedKind,
    labelPreferenceAnnouncement,
    leave,
    microphoneEnabled,
    microphones,
    minimized,
    mobileCallLayout,
    mobileWorkspaceOpen,
    openConversationChat,
    openMobileCallMenu,
    openPrejoin,
    participants,
    raisedUserIds,
    callReactions,
    callReadiness,
    phase,
    prejoinCamera,
    prejoinKind,
    prejoinMicrophone,
    preferDirectAudio,
    previewBusy,
    previewVideoRef,
    remoteAudioRef,
    screenShareEnabled,
    selectCamera,
    selectedCamera,
    selectedMicrophone,
    selectedSpeaker,
    selectMicrophone,
    selectSpeaker,
    selectPrejoinCamera,
    setCallWorkspaceTab,
    setEndConfirmationOpen,
    setMinimized,
    setMobileWorkspaceOpen,
    setPrejoinMicrophone,
    setPreferDirectAudio,
    setReadinessEnabled,
    setSelectedMicrophone,
    toggleCallControlLabels,
    toggleCamera,
    toggleMicrophone,
    togglePrejoinCamera,
    toggleScreenShare,
    toggleHand,
    sendCallReaction,
    muteParticipant,
    removeParticipant,
    speakers,
    transportMode,
    videoBlocked
  } = useCallSession({
    api,
    conversation,
    audioEnabled,
    videoEnabled,
    currentUserDisplayName,
    currentUserId,
    realtimeEvent,
    launchRequest,
    launchRequestId,
    launchReadinessMode,
    onLaunchRequestConsumed,
    onNavigate,
    onOpenChat,
    onSessionStateChange
  });
  const callStatusLabel = phase === "reconnecting"
    ? "Reconnecting"
    : phase === "leaving"
      ? "Leaving"
      : "Connected";
  const participantCountLabel =
    `${participants.length} ${participants.length === 1 ? "participant" : "participants"}`;
  const displayParticipants = participants.map((participant) => ({
    ...participant,
    handRaised: participant.userId ? raisedUserIds.has(participant.userId) : false
  }));

  return (
    <div className="call-control audio-call-control">
      {renderActions && <CallActions
        phase={phase}
        call={call}
        activeKind={activeKind}
        requestedKind={prejoinKind}
        joined={joined}
        accessRevoked={accessRevoked}
        audioEnabled={audioEnabled}
        videoEnabled={videoEnabled}
        showVideoAction={showVideoAction}
        onOpen={(kind) => void openPrejoin(kind)}
      />}

      {(phase === "prejoin" || phase === "joining") && createPortal(
        <CallPrejoinDialog
          kind={prejoinKind}
          conversationTitle={conversation.title || "Conversation"}
          joining={phase === "joining"}
          existingCall={call?.status === "active"}
          microphones={microphones}
          cameras={cameras}
          selectedMicrophone={selectedMicrophone}
          selectedCamera={selectedCamera}
          microphoneEnabled={prejoinMicrophone}
          cameraEnabled={prejoinCamera}
          previewBusy={previewBusy}
          previewVideoRef={previewVideoRef}
          error={error}
          readinessEnabled={callReadiness.enabled}
          readinessPhase={callReadiness.phase}
          readinessChecks={callReadiness.checks}
          readinessFailure={callReadiness.failure}
          readinessReportAvailable={Boolean(callReadiness.report)}
          directAudioAvailable={conversation.kind === "direct" && prejoinKind === "audio"}
          preferDirectAudio={preferDirectAudio}
          onMicrophone={setSelectedMicrophone}
          onCamera={(deviceId) => void selectPrejoinCamera(deviceId)}
          onMicrophoneEnabled={setPrejoinMicrophone}
          onCameraEnabled={(enabled) => void togglePrejoinCamera(enabled)}
          onReadinessEnabled={setReadinessEnabled}
          onPreferDirectAudio={setPreferDirectAudio}
          onDownloadReadinessReport={() => {
            if (callReadiness.report) downloadCallReadinessReport(callReadiness.report);
          }}
          onCancel={() => void leave()}
          onJoin={(publishMicrophone, publishCamera) => void join({ publishMicrophone, publishCamera })}
        />,
        document.body
      )}

      {joined && createPortal(
        <section
          ref={callDockRef}
          className={`call-dock audio-call-dock active-call-screen ${joinedKind === "video" ? "video-call-dock video-call-screen" : "audio-call-screen"} ${minimized ? "minimized" : ""}`}
          data-call-control-labels={callControlLabelsVisible ? "visible" : "hidden"}
          role={expandedCallModal ? "dialog" : "region"}
          aria-modal={expandedCallModal || undefined}
          aria-labelledby="call-title"
          tabIndex={expandedCallModal ? -1 : undefined}
        >
          <div className="audio-call-dock-heading">
            <div className={`call-heading-summary ${phase === "connected" ? "" : "has-call-status"}`}>
              <span className="eyebrow">{mediaLabel(joinedKind)} call</span>
              <h2 className="call-room-title" id="call-title">
                {conversation.title || "Conversation call"}
              </h2>
              <div className="call-progress-meta" aria-label="Call progress">
                <span className="call-progress-duration">
                  {formatCallDuration(elapsedSeconds)}
                </span>
                <span className="call-progress-separator" aria-hidden="true">·</span>
                <span
                  className="call-participant-count"
                  role="status"
                  aria-label={participantCountLabel}
                >
                  <span className="call-participant-count-visual" aria-hidden="true">
                    <span className="call-participant-count-number">
                      {participants.length}
                    </span>
                    <span className="call-participant-count-word">
                      {participants.length === 1 ? "participant" : "participants"}
                    </span>
                    <span className="call-participant-count-icon">
                      <AppIcon name="users" />
                    </span>
                  </span>
                </span>
                <span
                  className={`status-pill ${phase === "connected" ? "success call-status-connected" : "neutral"}`}
                  aria-live="polite"
                >
                  {callStatusLabel}
                </span>
                {joinedKind === "audio" && (
                  <span className={`status-pill ${transportMode === "direct" ? "success" : "neutral"}`} aria-live="polite">
                    {transportMode === "direct"
                      ? "Direct"
                      : transportMode === "connecting_direct"
                        ? "Switching to direct"
                        : transportMode === "livekit_fallback"
                          ? "LiveKit fallback"
                          : "LiveKit"}
                  </span>
                )}
              </div>
            </div>
            <div
              className="call-dock-heading-actions app-surface-control-cluster"
              role="group"
              aria-label="Call window controls"
            >
              <AppSurfaceControlButton
                className="button ghost compact"
                data-call-focus
                accessibleLabel={minimized ? "Show call" : "Minimize"}
                kind={minimized ? "expand" : "minimize"}
                label={minimized ? "Show call" : "Minimize"}
                aria-expanded={!minimized}
                aria-controls="active-call-details"
                onClick={() => {
                  setMobileWorkspaceOpen(false);
                  setMinimized((current) => !current);
                }}
              />
              {mobileCallLayout && !minimized && (
                <AppMenuTrigger
                  ref={callMenuTriggerRef}
                  className="button ghost compact call-menu-trigger"
                  accessibleLabel="Open call menu"
                  expanded={mobileWorkspaceOpen}
                  controls="call-workspace-sheet"
                  overlay
                  onClick={(event) => openMobileCallMenu(event.currentTarget)}
                />
              )}
            </div>
          </div>
          {/*
            * The companion's critical-status capsule.
            *
            * Minimizing hides #active-call-details, and that subtree held the
            * entire capture indicator and every control -- so a minimized call
            * reported its title, its duration and its participant count while
            * saying nothing about whether the microphone was live, and offered
            * no way to mute or hang up. This capsule lives outside that
            * subtree, so it is exactly what remains when the panel collapses.
            *
            * It renders only while minimized: expanded, the full capture
            * indicator and action row below already say all of this, and two
            * live regions reporting the same state is worse than one.
            */}
          {minimized && (
            <div className="call-critical-status">
              {/*
                * Named distinctly from the expanded panel's "Local capture
                * status". The two report the same facts and only one is ever
                * on screen, but the expanded one is hidden by a stylesheet
                * rule -- so before that stylesheet applies both sit in the
                * accessibility tree, and two live regions with one name is an
                * ambiguity no reader can resolve.
                */}
              <div className="call-critical-state" role="status" aria-label="Call status">
                <span className={microphoneEnabled ? "active" : "muted"}>
                  <AppIcon name={microphoneEnabled ? "mic" : "micOff"} />
                  Microphone {microphoneEnabled ? "on" : "off"}
                </span>
                {joinedKind === "video" && (
                  <span className={cameraEnabled ? "active" : "muted"}>
                    <AppIcon name={cameraEnabled ? "video" : "videoOff"} />
                    Camera {cameraEnabled ? "on" : "off"}
                  </span>
                )}
                {joinedKind === "video" && screenShareEnabled && (
                  <span className="active">
                    <AppIcon name="screenShare" />
                    Screen shared
                  </span>
                )}
              </div>
              <div
                className="call-critical-actions"
                role="group"
                aria-label="Call controls"
              >
                <button
                  className={`button compact ${microphoneEnabled ? "ghost" : "primary"}`}
                  type="button"
                  aria-label={microphoneEnabled ? "Mute microphone" : "Unmute microphone"}
                  aria-pressed={microphoneEnabled}
                  disabled={phase !== "connected"}
                  onClick={() => void toggleMicrophone()}
                >
                  <AppIcon name={microphoneEnabled ? "mic" : "micOff"} />
                </button>
                {/* Stop sharing is direct: never a step inside a reopened panel. */}
                {joinedKind === "video" && screenShareEnabled && (
                  <button
                    className="button ghost compact"
                    type="button"
                    aria-label="Stop sharing screen"
                    disabled={phase !== "connected"}
                    onClick={() => void toggleScreenShare()}
                  >
                    <AppIcon name="screenShareOff" />
                  </button>
                )}
                <button
                  className="button danger compact"
                  type="button"
                  aria-label="Leave call"
                  disabled={phase === "leaving"}
                  onClick={() => void leave()}
                >
                  <AppIcon name="phoneOff" />
                </button>
              </div>
            </div>
          )}
          {/*
            * Collapsed means collapsed. The minimize button has always
            * declared aria-expanded={!minimized} over this region, but the
            * region itself was hidden by a stylesheet rule alone -- so the
            * controls inside it stayed in the accessibility tree and the tab
            * order until that rule applied, and the capsule above duplicates
            * their labels by design.
            *
            * `inert` and aria-hidden state the collapse in the DOM instead.
            * Both, because they answer different questions: inert removes the
            * controls from the tab order, aria-hidden removes them from the
            * accessibility tree. It cannot be an unmount -- the media stage
            * lives in here, and tearing it down to minimize a call would
            * detach every track.
            */}
          <div
            id="active-call-details"
            className="active-call-details"
            inert={minimized || undefined}
            aria-hidden={minimized || undefined}
            onPointerDown={(event) => {
              if (
                mobileCallLayout
                && mobileWorkspaceOpen
                && event.currentTarget === event.target
              ) {
                closeMobileCallMenu();
              }
            }}
          >
            <div className="call-capture-indicator" role="status" aria-label="Local capture status">
              <strong>Capture</strong>
              <span className={microphoneEnabled ? "active" : undefined}>
                Microphone {microphoneEnabled ? "on" : "off"}
              </span>
              {joinedKind === "video" && (
                <span className={cameraEnabled ? "active" : undefined}>
                  Camera {cameraEnabled ? "on" : "off"}
                </span>
              )}
              {joinedKind === "video" && (
                <span className={screenShareEnabled ? "active" : undefined}>
                  Screen {screenShareEnabled ? "shared" : "not shared"}
                </span>
              )}
            </div>
            <section
              ref={callWorkspaceRef}
              className={`call-workspace-sheet ${mobileWorkspaceOpen ? "mobile-open" : ""}`}
              id="call-workspace-sheet"
              role={mobileCallLayout && mobileWorkspaceOpen ? "dialog" : undefined}
              aria-modal={mobileCallLayout && mobileWorkspaceOpen ? "true" : undefined}
              aria-labelledby={mobileCallLayout && mobileWorkspaceOpen ? "call-menu-title" : undefined}
              aria-label="Call workspace"
              tabIndex={mobileCallLayout && mobileWorkspaceOpen ? -1 : undefined}
            >
              <p className="visually-hidden" role="status" aria-live="polite">
                {labelPreferenceAnnouncement}
              </p>
              {mobileCallLayout && mobileWorkspaceOpen && (
                <header className="call-menu-header">
                  <h3 id="call-menu-title">Call menu</h3>
                  <AppMenuCloseButton
                    data-initial-focus
                    accessibleLabel="Close call menu"
                    onClick={closeMobileCallMenu}
                  />
                </header>
              )}
              <nav className="call-collaboration-links" aria-label="Call workspace">
                <button type="button" aria-pressed={callWorkspaceTab === "chat"} onClick={() => {
                  if (onNavigate || onOpenChat) {
                    openConversationChat();
                  } else {
                    setCallWorkspaceTab("chat");
                  }
                }}>
                  <AppIcon name="message" />
                  Chat
                </button>
                <button type="button" aria-label={mobileCallLayout ? "People" : "Directory"} aria-pressed={callWorkspaceTab === "people"} onClick={() => {
                  setCallWorkspaceTab("people");
                  if (onNavigate && !mobileCallLayout) {
                    setMobileWorkspaceOpen(false);
                    setMinimized(true);
                    onNavigate("/app/directory");
                  }
                }}>
                  <AppIcon name="users" />
                  People ({participants.length})
                </button>
                {onNavigate && (
                  <button type="button" aria-pressed={callWorkspaceTab === "files"} onClick={() => {
                    setCallWorkspaceTab("files");
                    setMobileWorkspaceOpen(false);
                    setMinimized(true);
                    onNavigate("/app/files");
                  }}>
                    <AppIcon name="file" />
                    Files
                  </button>
                )}
              </nav>
              <div className="call-workspace-body">
                {callWorkspaceTab === "chat" && (
                  <>
                    <strong>{conversation.title || "Conversation"}</strong>
                    <span>
                      {onOpenChat
                        ? "Open the room conversation without ending the call."
                        : "Continue messaging while the call stays connected."}
                    </span>
                    {(onNavigate || onOpenChat) && (
                      <button type="button" onClick={openConversationChat}>
                        {onOpenChat && !onNavigate ? "Open room chat" : "Open chat"}
                      </button>
                    )}
                  </>
                )}
                {callWorkspaceTab === "people" && (
                  <ul className="call-workspace-people">
                    {displayParticipants.map((participant) => (
                      <li key={participant.id}>
                        <span aria-hidden="true">{initials(participant.name)}</span>
                        <strong>{participant.name}{participant.local ? " (you)" : ""}</strong>
                        <small>{participant.handRaised ? "Hand raised · " : ""}{participant.microphoneEnabled ? "Microphone on" : "Muted"} · {participant.connectionQuality || "quality pending"}</small>
                        {call?.can_end && !participant.local && participant.providerIdentity && <span className="call-participant-moderation">
                          {participant.microphoneTrackSid && participant.microphoneEnabled && <button type="button" onClick={() => void muteParticipant(participant.providerIdentity!, participant.microphoneTrackSid!)}>Mute</button>}
                          <button className="danger-text" type="button" onClick={() => void removeParticipant(participant.providerIdentity!)}>Remove</button>
                        </span>}
                      </li>
                    ))}
                  </ul>
                )}
                {callWorkspaceTab === "files" && onNavigate && (
                  <>
                    <strong>Shared files</strong>
                    <span>Open authorized conversation files without ending the call.</span>
                    <button type="button" onClick={() => {
                      setMobileWorkspaceOpen(false);
                      setMinimized(true);
                      onNavigate("/app/files");
                    }}>Open files</button>
                  </>
                )}
              </div>
              {mobileCallLayout && mobileWorkspaceOpen && (
                <div className="call-menu-secondary-actions">
                  <button
                    className="button ghost call-control-label-toggle"
                    type="button"
                    onClick={toggleCallControlLabels}
                  >
                    <AppIcon name={callControlLabelsVisible ? "eyeOff" : "eye"} />
                    {callControlLabelsVisible ? "Hide labels" : "Show labels"}
                  </button>
                  <button
                    className="button danger"
                    type="button"
                    disabled={phase === "leaving"}
                    onClick={() => void leave()}
                  >
                    <AppIcon name="phoneOff" />
                    Leave call
                  </button>
                  {call?.can_end && <button
                    className="button danger"
                    type="button"
                    disabled={phase === "leaving"}
                    onClick={() => setEndConfirmationOpen(true)}
                  >
                    <AppIcon name="phoneOff" />
                    End for everyone
                  </button>}
                </div>
              )}
            </section>
            <div className={`call-stage ${callReadiness.enabled ? "has-call-readiness" : ""}`}>
              {error && <div className="form-error" role="alert">{error}</div>}
              <div className="call-policy-notice" role="note">Recording and transcription are off by workspace policy.</div>
              {callReactions.length > 0 && <div className="call-reaction-overlay" aria-live="polite">{callReactions.slice(-5).map((reaction) => <span key={reaction.id}>{reaction.emoji}</span>)}</div>}
              {(audioBlocked || videoBlocked) && <div className="inline-notice" role="status"><span>Browser media playback is paused.</span><button className="button ghost compact" type="button" onClick={() => void enablePlayback()}>{joinedKind === "audio" ? "Enable call audio" : "Enable call media"}</button></div>}
              {callReadiness.enabled && <CallReadinessPanel readiness={callReadiness} />}
              {joinedKind === "video" && (
                <VideoParticipantGrid
                  participants={prioritizeVideoParticipants(displayParticipants)}
                />
              )}
              {joinedKind === "audio" && (
                <AudioParticipantStage participants={displayParticipants} />
              )}
            </div>
            <div className="call-device-grid">
              <div className="audio-device-row">
                <label htmlFor="active-audio-input">Microphone</label>
                <select id="active-audio-input" value={selectedMicrophone} disabled={phase !== "connected" || microphones.length === 0} onChange={(event) => void selectMicrophone(event.target.value)}>
                  {microphones.length === 0 && <option value="">Default microphone</option>}
                  {microphones.map((device, index) => <option key={device.deviceId || `microphone-${index}`} value={device.deviceId}>{device.label || `Microphone ${index + 1}`}</option>)}
                </select>
              </div>
              <div className="audio-device-row">
                <label htmlFor="active-audio-output">Speaker</label>
                <select id="active-audio-output" value={selectedSpeaker} disabled={phase !== "connected" || speakers.length === 0} onChange={(event) => void selectSpeaker(event.target.value)}>
                  {speakers.length === 0 && <option value="">Browser default speaker</option>}
                  {speakers.map((device, index) => <option key={device.deviceId || `speaker-${index}`} value={device.deviceId}>{device.label || `Speaker ${index + 1}`}</option>)}
                </select>
              </div>
              {joinedKind === "video" && <div className="audio-device-row">
                <label htmlFor="active-video-input">Camera</label>
                <select id="active-video-input" value={selectedCamera} disabled={phase !== "connected" || cameras.length === 0} onChange={(event) => void selectCamera(event.target.value)}>
                  {cameras.length === 0 && <option value="">Default camera</option>}
                  {cameras.map((device, index) => <option key={device.deviceId || `camera-${index}`} value={device.deviceId}>{device.label || `Camera ${index + 1}`}</option>)}
                </select>
              </div>}
            </div>
            <div className="call-collaboration-actions">
              <button className={`button compact ${currentUserId && raisedUserIds.has(currentUserId) ? "primary" : "ghost"}`} type="button" aria-pressed={currentUserId ? raisedUserIds.has(currentUserId) : false} disabled={phase !== "connected"} onClick={() => void toggleHand()}><span className="call-action-glyph" aria-hidden="true">✋</span><span className="call-action-label">{currentUserId && raisedUserIds.has(currentUserId) ? "Lower hand" : "Raise hand"}</span></button>
              <div className="call-reaction-actions" aria-label="Call reactions">{["👍", "👏", "❤️", "😂", "🎉"].map((emoji) => <button className="button ghost compact" type="button" key={emoji} aria-label={`React ${emoji}`} onClick={() => void sendCallReaction(emoji)}>{emoji}</button>)}</div>
            </div>
            <div className="audio-call-actions">
              <button
                className={`button compact call-action-microphone ${microphoneEnabled ? "primary" : "ghost"}`}
                type="button"
                aria-label={microphoneEnabled ? "Mute microphone" : "Unmute microphone"}
                aria-pressed={microphoneEnabled}
                disabled={phase !== "connected"}
                onClick={() => void toggleMicrophone()}
              >
                <span className="call-action-glyph" aria-hidden="true">
                  <AppIcon name={microphoneEnabled ? "mic" : "micOff"} />
                </span>
                <span className="call-action-label">
                  {mobileCallLayout
                    ? "Mic"
                    : microphoneEnabled ? "Mute microphone" : "Unmute microphone"}
                </span>
              </button>
              {joinedKind === "video" && (
                <button
                  className={`button compact call-action-camera ${cameraEnabled ? "primary" : "ghost"}`}
                  type="button"
                  aria-label={cameraEnabled ? "Turn camera off" : "Turn camera on"}
                  aria-pressed={cameraEnabled}
                  disabled={phase !== "connected"}
                  onClick={() => void toggleCamera()}
                >
                  <span className="call-action-glyph" aria-hidden="true">
                    <AppIcon name={cameraEnabled ? "video" : "videoOff"} />
                  </span>
                  <span className="call-action-label">
                    {mobileCallLayout
                      ? "Camera"
                      : cameraEnabled ? "Turn camera off" : "Turn camera on"}
                  </span>
                </button>
              )}
              {joinedKind === "video" && (
                <button
                  className={`button compact call-action-screen ${screenShareEnabled ? "primary" : "ghost"}`}
                  type="button"
                  aria-label={screenShareEnabled ? "Stop sharing screen" : "Share screen"}
                  aria-pressed={screenShareEnabled}
                  disabled={phase !== "connected"}
                  onClick={() => void toggleScreenShare()}
                >
                  <span className="call-action-glyph" aria-hidden="true">
                    <AppIcon name={screenShareEnabled ? "screenShareOff" : "screenShare"} />
                  </span>
                  <span className="call-action-label">
                    {mobileCallLayout
                      ? "Screen"
                      : screenShareEnabled ? "Stop sharing screen" : "Share screen"}
                  </span>
                </button>
              )}
              {mobileCallLayout && (
                <button
                  className={`button compact call-action-people call-action-more ${mobileWorkspaceOpen && callWorkspaceTab === "people" ? "primary" : "ghost"}`}
                  type="button"
                  aria-label="People"
                  aria-expanded={mobileWorkspaceOpen && callWorkspaceTab === "people"}
                  aria-controls="call-workspace-sheet"
                  onClick={(event) => {
                    setCallWorkspaceTab("people");
                    openMobileCallMenu(event.currentTarget);
                  }}
                >
                  <span className="call-action-glyph" aria-hidden="true">
                    <AppIcon name="users" />
                  </span>
                  <span className="call-action-label">People</span>
                </button>
              )}
              <button
                className="button danger compact call-action-leave"
                type="button"
                aria-label="Leave call"
                disabled={phase === "leaving"}
                onClick={() => void leave()}
              >
                <span className="call-action-glyph" aria-hidden="true">
                  <AppIcon name="phoneOff" />
                </span>
                <span className="call-action-label">
                  {mobileCallLayout ? "Leave" : "Leave call"}
                </span>
              </button>
              {call?.can_end && !mobileCallLayout && (
                <button
                  className="button danger compact call-action-end"
                  type="button"
                  disabled={phase === "leaving"}
                  onClick={() => setEndConfirmationOpen(true)}
                >
                  <span className="call-action-glyph" aria-hidden="true">
                    <AppIcon name="phoneOff" />
                  </span>
                  <span className="call-action-label">End for everyone</span>
                </button>
              )}
            </div>
          </div>
          <div ref={remoteAudioRef} className="remote-audio-tracks" aria-hidden="true" />
        </section>,
        document.body
      )}

      {joined && endConfirmationOpen && call?.can_end && createPortal(
        <div
          className="modal-backdrop call-end-confirmation-backdrop"
          onPointerDown={(event) => {
            if (event.currentTarget === event.target) {
              setEndConfirmationOpen(false);
            }
          }}
        >
          <section
            ref={endConfirmationRef}
            className="modal-dialog call-end-confirmation-dialog"
            role="dialog"
            aria-modal="true"
            aria-labelledby="call-end-confirmation-title"
            aria-describedby="call-end-confirmation-description"
            tabIndex={-1}
          >
            <header className="app-dialog-heading">
              <h2 id="call-end-confirmation-title">End call for everyone?</h2>
              <AppSurfaceControlButton
                accessibleLabel="Close end call confirmation"
                kind="close"
                onClick={() => setEndConfirmationOpen(false)}
              />
            </header>
            <p id="call-end-confirmation-description">
              This ends the call for every participant. This action cannot be undone.
            </p>
            <div className="form-actions">
              <button
                className="button ghost"
                type="button"
                data-initial-focus
                onClick={() => setEndConfirmationOpen(false)}
              >
                Cancel
              </button>
              <button
                className="button danger"
                type="button"
                onClick={() => {
                  setEndConfirmationOpen(false);
                  void endForEveryone();
                }}
              >
                End for everyone
              </button>
            </div>
          </section>
        </div>,
        document.body
      )}

      {!joined && phase === "ended" && error && createPortal(
        <CallTerminalNotice
          title={accessRevoked ? `${mediaLabel(currentMediaKind)} access revoked` : `${mediaLabel(currentMediaKind)} call ended`}
          message={error}
          error={accessRevoked}
          autoDismiss={!accessRevoked}
          action={call?.can_end && <button className="button danger compact" type="button" onClick={() => void endForEveryone()}>End for everyone</button>}
          onDismiss={dismissTerminalNotice}
        />,
        document.body
      )}

      {!joined && phase === "error" && error && createPortal(
        <CallTerminalNotice
          title={`${mediaLabel(currentMediaKind)} call unavailable`}
          message={error}
          error
          action={call?.can_end && <button className="button danger compact" type="button" onClick={() => void endForEveryone()}>End for everyone</button>}
          onDismiss={dismissTerminalNotice}
        />,
        document.body
      )}
    </div>
  );
}
