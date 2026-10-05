import AVFoundation
import Combine
import LiveKit

@MainActor final class CallMedia: NSObject, ObservableObject, RoomDelegate {
    @Published private(set) var room: Room?
    @Published private(set) var connectionLabel = "Disconnected"
    @Published private(set) var microphoneEnabled = false
    @Published private(set) var cameraEnabled = false
    var onConnectionChanged: (@MainActor () -> Void)?
    private var generation: UInt64 = 0
    private var ownsAudioActivation = false
    private var authorize: (@MainActor () async throws -> Void)?
    override init() {
        super.init()
        AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = false
        try? AudioManager.shared.setEngineAvailability(.none)
    }
    static func requestPermissions(video: Bool) async throws {
        let microphone = await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard microphone else { throw NativeClientError.microphoneDenied }
        if video && !(await AVCaptureDevice.requestAccess(for: .video)) { throw NativeClientError.cameraDenied }
    }
    func connect(_ admission: CallAdmission, authorize: @escaping @MainActor () async throws -> Void) async throws {
        guard admission.data.status == "active", let expiry = Wire.date(admission.data.expiresAt), expiry > Date() else { throw NativeClientError.invalidResponse }
        try await connect(credential: admission.credential, video: admission.data.isVideo, authorize: authorize)
    }
    func connect(credential: CallCredential, video: Bool, authorize: @escaping @MainActor () async throws -> Void) async throws {
        guard let server = URLComponents(string: credential.serverUrl),
              ["wss", "https"].contains(server.scheme ?? ""), server.host != nil, server.user == nil, server.password == nil,
              server.fragment == nil, credential.expiresIn > 0, !credential.participantToken.isEmpty else {
            throw NativeClientError.invalidResponse
        }
        await disconnect(); let expected = generation; self.authorize = authorize
        try await authorize(); guard expected == generation else { throw NativeClientError.sessionChanged }
        let opened = Room(delegate: self); room = opened; connectionLabel = "Connecting"
        do {
            let ice = (credential.iceServers ?? []).map { IceServer(urls: $0.urls, username: $0.username, credential: $0.credential) }
            try await opened.connect(url: credential.serverUrl, token: credential.participantToken, connectOptions: ConnectOptions(iceServers: ice, enableMicrophone: false))
            try await authorize(); guard expected == generation, room === opened else { throw NativeClientError.sessionChanged }
            _ = try await opened.localParticipant.setMicrophone(enabled: true)
            try await authorize(); guard expected == generation, room === opened else { throw NativeClientError.sessionChanged }
            microphoneEnabled = true
            if video {
                _ = try await opened.localParticipant.setCamera(enabled: true)
                try await authorize(); guard expected == generation, room === opened else { throw NativeClientError.sessionChanged }
                cameraEnabled = true
            }
            connectionLabel = "Connected"
        } catch {
            if expected == generation { await disconnect() } else { await opened.disconnect() }
            throw error
        }
    }
    func sendDtmf(_ digit: String) async throws {
        guard digit.count == 1, let character = digit.first, let index = "0123456789*#ABCD".firstIndex(of: character),
              let opened = room, opened.connectionState == .connected, let authorize else { throw NativeClientError.invalidResponse }
        let expected = generation
        try await authorize(); guard expected == generation, room === opened else { throw NativeClientError.sessionChanged }
        let code = UInt32("0123456789*#ABCD".distance(from: "0123456789*#ABCD".startIndex, to: index))
        try await opened.localParticipant.publishDtmf(code: code, digit: digit)
        try await authorize(); guard expected == generation else { throw NativeClientError.sessionChanged }
    }
    /// Only CallKit's activation callback permits SDK audio hardware to run.
    func audioActivated(_ active: Bool) {
        if active { guard room != nil else { return }; ownsAudioActivation = true }
        else { guard ownsAudioActivation || room != nil else { return }; ownsAudioActivation = false }
        do { try AudioManager.shared.setEngineAvailability(active ? .default : .none) }
        catch { connectionLabel = "Audio unavailable"; onConnectionChanged?() }
    }
    func setMicrophone(_ enabled: Bool) async throws {
        guard let opened = room, let authorize else { throw NativeClientError.sessionChanged }
        let expected = generation
        try await authorize(); guard expected == generation else { throw NativeClientError.sessionChanged }
        _ = try await opened.localParticipant.setMicrophone(enabled: enabled)
        try await authorize(); guard expected == generation else { await opened.disconnect(); throw NativeClientError.sessionChanged }
        microphoneEnabled = enabled
    }
    func setCamera(_ enabled: Bool) async throws {
        guard let opened = room, let authorize else { throw NativeClientError.sessionChanged }
        let expected = generation
        if enabled { guard await AVCaptureDevice.requestAccess(for: .video) else { throw NativeClientError.cameraDenied } }
        try await authorize(); guard expected == generation else { throw NativeClientError.sessionChanged }
        _ = try await opened.localParticipant.setCamera(enabled: enabled)
        try await authorize(); guard expected == generation else { await opened.disconnect(); throw NativeClientError.sessionChanged }
        cameraEnabled = enabled
    }
    /// Capture cleanup is allowed after authority disappears.
    func stopCamera() async {
        cameraEnabled = false
        if let opened = room { _ = try? await opened.localParticipant.setCamera(enabled: false) }
    }
    /// Revoke local media synchronously; draining the old room cannot close a replacement.
    func invalidate() -> Room? {
        generation &+= 1; authorize = nil
        audioActivated(false)
        let old = room; room = nil; microphoneEnabled = false; cameraEnabled = false; connectionLabel = "Disconnected"
        return old
    }
    func disconnect() async { let old = invalidate(); await old?.disconnect() }
    nonisolated func room(_ room: Room, didUpdateConnectionState connectionState: ConnectionState, from oldConnectionState: ConnectionState) {
        Task { @MainActor [weak self] in
            guard let self, self.room === room else { return }
            self.connectionLabel = String(describing: connectionState)
            if connectionState != .connected { self.audioActivated(false) }
            self.onConnectionChanged?()
        }
    }
    nonisolated func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        Task { @MainActor [weak self] in
            guard let self, self.room === room else { return }
            self.audioActivated(false); self.connectionLabel = "Disconnected"; self.onConnectionChanged?()
        }
    }
}
