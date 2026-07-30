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

export type {
  CallApi,
  CallPanelSessionState,
  CallPhase
} from "./callContracts";
export { callPublishDefaults, callRtcConfig } from "./callMedia";

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
  realtimeEvent,
  showVideoAction = true,
  launchRequest,
  launchRequestId,
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
    phase,
    prejoinCamera,
    prejoinKind,
    prejoinMicrophone,
    previewBusy,
    previewVideoRef,
    remoteAudioRef,
    screenShareEnabled,
    selectCamera,
    selectedCamera,
    selectedMicrophone,
    selectMicrophone,
    selectPrejoinCamera,
    setCallWorkspaceTab,
    setEndConfirmationOpen,
    setMinimized,
    setMobileWorkspaceOpen,
    setPrejoinMicrophone,
    setSelectedMicrophone,
    toggleCallControlLabels,
    toggleCamera,
    toggleMicrophone,
    togglePrejoinCamera,
    toggleScreenShare,
    videoBlocked
  } = useCallSession({
    api,
    conversation,
    audioEnabled,
    videoEnabled,
    currentUserDisplayName,
    realtimeEvent,
    launchRequest,
    launchRequestId,
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
          onMicrophone={setSelectedMicrophone}
          onCamera={(deviceId) => void selectPrejoinCamera(deviceId)}
          onMicrophoneEnabled={setPrejoinMicrophone}
          onCameraEnabled={(enabled) => void togglePrejoinCamera(enabled)}
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
          <div
            id="active-call-details"
            className="active-call-details"
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
                    {participants.map((participant) => (
                      <li key={participant.id}>
                        <span aria-hidden="true">{initials(participant.name)}</span>
                        <strong>{participant.name}{participant.local ? " (you)" : ""}</strong>
                        <small>{participant.microphoneEnabled ? "Microphone on" : "Muted"}</small>
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
            <div className="call-stage">
              {error && <div className="form-error" role="alert">{error}</div>}
              {(audioBlocked || videoBlocked) && <div className="inline-notice" role="status"><span>Browser media playback is paused.</span><button className="button ghost compact" type="button" onClick={() => void enablePlayback()}>{joinedKind === "audio" ? "Enable call audio" : "Enable call media"}</button></div>}
              {joinedKind === "video" && (
                <VideoParticipantGrid
                  participants={prioritizeVideoParticipants(participants)}
                />
              )}
              {joinedKind === "audio" && (
                <AudioParticipantStage participants={participants} />
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
              {joinedKind === "video" && <div className="audio-device-row">
                <label htmlFor="active-video-input">Camera</label>
                <select id="active-video-input" value={selectedCamera} disabled={phase !== "connected" || cameras.length === 0} onChange={(event) => void selectCamera(event.target.value)}>
                  {cameras.length === 0 && <option value="">Default camera</option>}
                  {cameras.map((device, index) => <option key={device.deviceId || `camera-${index}`} value={device.deviceId}>{device.label || `Camera ${index + 1}`}</option>)}
                </select>
              </div>}
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
        <div className={`audio-call-terminal-notice ${accessRevoked ? "error" : ""}`} role={accessRevoked ? "alert" : "status"}>
          <strong>{accessRevoked ? `${mediaLabel(currentMediaKind)} access revoked` : `${mediaLabel(currentMediaKind)} call ended`}</strong>
          <span>{error}</span>
          {call?.can_end && <button className="button danger compact" type="button" onClick={() => void endForEveryone()}>End for everyone</button>}
        </div>,
        document.body
      )}

      {!joined && phase === "error" && error && createPortal(
        <div className="audio-call-terminal-notice error" role="alert">
          <strong>{mediaLabel(currentMediaKind)} call unavailable</strong>
          <span>{error}</span>
          {call?.can_end && <button className="button danger compact" type="button" onClick={() => void endForEveryone()}>End for everyone</button>}
        </div>,
        document.body
      )}
    </div>
  );
}
