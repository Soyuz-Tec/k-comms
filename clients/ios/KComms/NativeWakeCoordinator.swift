import AVFoundation
import CallKit
import Combine
import Foundation
import PushKit
import UIKit

/// Default closed. Enabling this in a signed deployment requires the reviewed
/// APNs entitlements, operator/device qualification and explicit user consent.
@MainActor final class NativeWakeCoordinator: NSObject, ObservableObject, PKPushRegistryDelegate, CXProviderDelegate {
    static let shared = NativeWakeCoordinator()
    @Published private(set) var notice = NativePushAvailability.explanation
    @Published private(set) var pending = false
    let media = CallMedia()
    private var client: ApiClient?
    private var slot: NativeCallSlot?
    private let slotOwner = UUID()
    private var stamp: IdentityStamp?
    private var generation: UInt64 = 0
    private var registry: PKPushRegistry?
    private var provider: CXProvider!
    private var registration: NativePushRegistration?
    private var incoming: (uuid: UUID, hint: NativeWakeHint, generation: UInt64, stamp: IdentityStamp)?
    private var admission: NativeWakeAdmission?
    private var lease: AuthorityLease?
    private var phoneWorkspace: UInt64?
    private var seen: [String: TimeInterval] = [:]
    private var timeout: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    private var audioActive = false
    private var registering = false
    private var token: String?
    private var environment: String { Bundle.main.object(forInfoDictionaryKey: "NativePushEnvironment") as? String ?? "sandbox" }
    private var qualified: Bool { Bundle.main.object(forInfoDictionaryKey: "NativePushDeviceQualified") as? Bool == true }
    private var installation: String {
        let key = "nativePushInstallationID"
        if let id = UserDefaults.standard.string(forKey: key), UUID(uuidString: id) != nil { return id }
        let id = UUID().uuidString; UserDefaults.standard.set(id, forKey: key); return id
    }
    override init() {
        super.init()
        let config = CXProviderConfiguration(); config.maximumCallGroups = 1; config.maximumCallsPerCallGroup = 1
        config.includesCallsInRecents = false; config.supportedHandleTypes = [.generic]; config.supportsVideo = false
        provider = CXProvider(configuration: config); provider.setDelegate(self, queue: .main)
    }
    /// Cold-launch PushKit reporting cannot wait for an HTTP restore. The
    /// previously approved local qualification/consent may recreate only the
    /// registry; missing/locked credentials still report and end the hint.
    func bootstrap(_ api: ApiClient?, slot: NativeCallSlot) {
        self.slot = slot; client = api
        guard qualified, UserDefaults.standard.bool(forKey: "nativePushUserConsent"),
              UserDefaults.standard.bool(forKey: "nativePushPreviouslyApproved") else { return }
        if let api {
            let expected = generation
            Task { if let stamp = try? await api.stamp(), expected == generation, client === api { self.stamp = stamp } }
        }
        createRegistry()
    }
    private func createRegistry() {
        guard registry == nil else { return }
        let registry = PKPushRegistry(queue: .main); registry.delegate = self; self.registry = registry; registry.desiredPushTypes = [.voIP]
    }
    func attach(_ api: ApiClient, slot: NativeCallSlot) async {
        if client !== api { await detach(); client = api; self.slot = slot }
        guard qualified, UserDefaults.standard.bool(forKey: "nativePushUserConsent") else { return }
        await enable()
    }
    func enable() async {
        guard qualified, let client, let application = Bundle.main.bundleIdentifier else {
            notice = "Background calls need an operator-qualified, signed iOS build."; return
        }
        let expected = generation
        do {
            _ = try await client.me(); let stamp = try await client.stamp(); let config = try await client.nativePushConfiguration()
            try await client.assertCurrent(stamp)
            guard expected == generation, self.client === client,
                  config.approves(channel: "apns_voip", application: application, environment: environment, qualified: qualified),
                  AVAudioSession.sharedInstance().recordPermission == .granted else { throw NativeClientError.featureUnavailable }
            self.stamp = stamp; UserDefaults.standard.set(true, forKey: "nativePushUserConsent")
            createRegistry()
            notice = "Confirming the provider token and current native registration…"
            if let token { await register(token, expected: expected) }
        } catch {
            guard expected == generation, self.client === client else { return }
            notice = "Native wake is unavailable. Sign in, grant microphone access and confirm deployment qualification."
            registry?.desiredPushTypes = []; registry = nil
        }
    }
    /// Invalidate local callback generations before best-effort CAS cleanup.
    /// Session revocation also erases provider ciphertext in the owner transaction.
    func detach() async {
        let old = client; let row = registration
        generation &+= 1; registry?.desiredPushTypes = []; registry = nil; client = nil; stamp = nil
        registration = nil; token = nil; registering = false; seen.removeAll()
        UserDefaults.standard.set(false, forKey: "nativePushUserConsent")
        UserDefaults.standard.set(false, forKey: "nativePushPreviouslyApproved")
        await end(reason: .failed); slot = nil; notice = NativePushAvailability.explanation
        if let old, let row { try? await old.revokeNativePush(channel: row.channel, version: row.version) }
    }
    func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        guard registry === self.registry, type == .voIP else { return }
        let value = pushCredentials.token.map { String(format: "%02x", $0) }.joined(); token = value
        let expected = generation; Task { await register(value, expected: expected) }
    }
    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        guard registry === self.registry, type == .voIP else { return }
        token = nil; let old = client; let row = registration; registration = nil
        Task { if let old, let row { try? await old.revokeNativePush(channel: row.channel, version: row.version) } }
    }
    private func register(_ token: String, expected: UInt64) async {
        guard !registering, expected == generation, let client, let stamp, let application = Bundle.main.bundleIdentifier else { return }
        registering = true
        defer {
            if expected == generation {
                registering = false
                if let next = self.token, next != token { Task { await self.register(next, expected: expected) } }
            }
        }
        do {
            try await client.assertCurrent(stamp)
            let config = try await client.nativePushConfiguration()
            guard UserDefaults.standard.bool(forKey: "nativePushUserConsent"),
                  AVAudioSession.sharedInstance().recordPermission == .granted,
                  config.approves(channel: "apns_voip", application: application, environment: environment, qualified: qualified) else { throw NativeClientError.featureUnavailable }
            let rows = try await client.nativePushRegistrations(); try await client.assertCurrent(stamp)
            guard expected == generation, self.client === client,
                  AVAudioSession.sharedInstance().recordPermission == .granted else { throw NativeClientError.sessionChanged }
            let current = rows.first { $0.channel == "apns_voip" }
            let result = try await client.registerNativePush(channel: "apns_voip", application: application,
                environment: environment, token: token, installation: installation, version: current?.version ?? 0)
            try await client.assertCurrent(stamp)
            guard expected == generation, self.client === client, result.registration.deviceId == stamp.identity.device,
                  result.registration.status == "active" else { throw NativeClientError.sessionChanged }
            guard self.token != nil, AVAudioSession.sharedInstance().recordPermission == .granted else {
                try? await client.revokeNativePush(channel: result.registration.channel, version: result.registration.version)
                throw NativeClientError.featureUnavailable
            }
            registration = result.registration
            notice = "Native registration is current. Device and provider qualification remain deployment requirements."
            UserDefaults.standard.set(true, forKey: "nativePushPreviouslyApproved")
            // The deferred flight submits a newer token with current CAS
            // authority only after this registration has fully completed.
        } catch { if expected == generation { notice = "Native registration could not be confirmed. Keep the app open." } }
    }
    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload,
                      for type: PKPushType, completion: @escaping () -> Void) {
        // Apple requires every delivered VoIP push to be reported promptly,
        // including malformed/expired hints. No HTTP, permissions or media I/O
        // precedes this report; invalid hints are immediately ended afterward.
        let uuid = UUID(); let hint = try? NativeWakeHint(payload: payload.dictionaryPayload)
        let uptime = ProcessInfo.processInfo.systemUptime
        seen = seen.filter { $0.value > uptime }
        let duplicate = hint.map { seen[$0.id] != nil } ?? false
        let hasReplayBudget = seen.count < 128
        if let hint, !duplicate, hasReplayBudget { seen[hint.id] = hint.monotonicDeadline }
        let canAccept = !duplicate && hasReplayBudget && registry === self.registry && type == .voIP && qualified && incoming == nil &&
            hint != nil && stamp != nil && client != nil && slot?.acquire(slotOwner) == true
        if canAccept, let hint, let stamp { incoming = (uuid, hint, generation, stamp); pending = true }
        let update = CXCallUpdate(); update.remoteHandle = CXHandle(type: .generic, value: "K-Comms call")
        update.localizedCallerName = "K-Comms call"; update.hasVideo = false
        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
            completion()
            Task { @MainActor in
                guard let self else { return }
                guard canAccept, error == nil, self.incoming?.uuid == uuid,
                      UserDefaults.standard.bool(forKey: "nativePushUserConsent"),
                      AVAudioSession.sharedInstance().recordPermission == .granted else {
                    self.provider.reportCall(with: uuid, endedAt: Date(), reason: .failed)
                    if self.incoming?.uuid == uuid { await self.end(reason: .failed) }; return
                }
                self.timeout?.cancel()
                self.timeout = Task { [weak self] in
                    guard let self, let bound = self.incoming else { return }
                    let delay = max(0, bound.hint.monotonicDeadline - ProcessInfo.processInfo.systemUptime)
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    guard !Task.isCancelled, self.incoming?.uuid == uuid, self.admission == nil else { return }
                    await self.end(reason: .unanswered)
                }
            }
        }
    }
    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        guard let bound = incoming, bound.uuid == action.callUUID, let client else { action.fail(); return }
        Task {
            do {
                try guardIncoming(bound)
                guard AVAudioSession.sharedInstance().recordPermission == .granted else { throw NativeClientError.microphoneDenied }
                _ = try await client.me(); try await client.assertCurrent(bound.stamp); try guardIncoming(bound)
                // This is the sole one-use resolution, after the user's OS answer.
                let workspace = try? await client.captureWorkspaceAuthority(bound.stamp)
                let admitted = try await client.admitNativeWake(bound.hint.id)
                if case .phone = admitted {
                    guard let workspace else { throw NativeClientError.workspaceUnavailable }
                    try await client.assertWorkspaceAuthority(workspace, stamp: bound.stamp)
                    phoneWorkspace = workspace
                }
                try await client.assertCurrent(bound.stamp); try guardIncoming(bound)
                guard admitted.credential.expiresIn > 0 else { throw NativeClientError.invalidResponse }
                admission = admitted; lease = AuthorityLease(stamp: bound.stamp,
                    credentialExpires: Date().addingTimeInterval(TimeInterval(admitted.credential.expiresIn)), lastObserved: Date())
                timeout?.cancel(); timeout = nil
                try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth])
                try await validate(); try guardAnswered(bound)
                try await media.connect(credential: admitted.credential, video: false) { [weak self] in
                    guard let self else { throw NativeClientError.sessionChanged }; try await self.authorize(bound)
                }
                try await validate(); try guardAnswered(bound); action.fulfill()
                media.audioActivated(audioActive); startMonitor(bound)
            } catch { action.fail(); if incoming?.uuid == bound.uuid { await end(reason: .failed) } }
        }
    }
    private func guardIncoming(_ bound: (uuid: UUID, hint: NativeWakeHint, generation: UInt64, stamp: IdentityStamp)) throws {
        guard bound.generation == generation, incoming?.uuid == bound.uuid, bound.hint.current(), admission == nil else { throw NativeClientError.sessionChanged }
    }
    private func guardAnswered(_ bound: (uuid: UUID, hint: NativeWakeHint, generation: UInt64, stamp: IdentityStamp)) throws {
        guard bound.generation == generation, incoming?.uuid == bound.uuid, admission != nil else { throw NativeClientError.sessionChanged }
    }
    private func authorize(_ bound: (uuid: UUID, hint: NativeWakeHint, generation: UInt64, stamp: IdentityStamp)) async throws {
        try guardAnswered(bound)
        guard AVAudioSession.sharedInstance().recordPermission == .granted else { throw NativeClientError.microphoneDenied }
        guard let client, let lease, lease.valid(stamp: bound.stamp) else { throw NativeClientError.sessionChanged }
        try await client.assertCurrent(bound.stamp)
        if lease.needsRevalidation() { try await validate() }; try guardAnswered(bound)
    }
    private func validate() async throws {
        guard let client, let bound = incoming, let admission, let lease, lease.credentialIsCurrent() else { throw NativeClientError.sessionChanged }
        try await client.assertCurrent(bound.stamp); let identity = try await client.me()
        switch admission {
        case .conversation(let admitted):
            let actual = try await client.activeCall(conversation: admitted.data.conversationId)
            let people = try await client.participants(admitted.data)
            guard actual?.id == admitted.data.id, actual?.status == "active", (Wire.date(actual?.expiresAt ?? "") ?? .distantPast) > Date(),
                  people.contains(where: { $0.userId == bound.stamp.identity.user && $0.status == "admitted" }),
                  admitted.data.isVideo ? identity.capabilities.allowVideoCalls : identity.capabilities.allowAudioCalls else { throw NativeClientError.sessionChanged }
        case .phone(let admitted):
            guard let phoneWorkspace else { throw NativeClientError.workspaceUnavailable }
            try await client.assertWorkspaceAuthority(phoneWorkspace, stamp: bound.stamp)
            let actual = try await client.phoneCall(admitted.data.id)
            try await client.assertWorkspaceAuthority(phoneWorkspace, stamp: bound.stamp)
            guard identity.user.hasWorkspaceAccess, actual.isActive, actual.activeOnThisDevice else { throw NativeClientError.sessionChanged }
        }
        try await client.assertCurrent(bound.stamp); try guardAnswered(bound); self.lease?.observe()
    }
    private func startMonitor(_ bound: (uuid: UUID, hint: NativeWakeHint, generation: UInt64, stamp: IdentityStamp)) {
        monitor?.cancel(); monitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self, self.incoming?.uuid == bound.uuid else { return }
                do { try await self.authorize(bound); self.media.audioActivated(self.audioActive) }
                catch { await self.end(reason: .failed); return }
            }
        }
    }
    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        guard incoming?.uuid == action.callUUID else { action.fail(); return }
        Task { await end(reason: .remoteEnded, notifyOwner: true); action.fulfill() }
    }
    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        guard let bound = incoming, bound.uuid == action.callUUID else { action.fail(); return }
        Task { do { try await authorize(bound); try await media.setMicrophone(!action.isMuted); try guardAnswered(bound); action.fulfill() } catch { action.fail(); await end(reason: .failed) } }
    }
    func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) { action.fail(); Task { await end(reason: .failed) } }
    func providerDidReset(_ provider: CXProvider) { Task { await end(reason: .failed) } }
    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        audioActive = true
        guard let bound = incoming, admission != nil else { return }
        Task { do { try await authorize(bound); media.audioActivated(audioActive) } catch { await end(reason: .failed) } }
    }
    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) { audioActive = false; media.audioActivated(false) }
    func end(reason: CXCallEndedReason = .remoteEnded, notifyOwner: Bool = false) async {
        let ended = admission; let oldStamp = incoming?.stamp; let oldClient = client
        let uuid = incoming?.uuid; incoming = nil; admission = nil; lease = nil; phoneWorkspace = nil; pending = false
        timeout?.cancel(); monitor?.cancel(); timeout = nil; monitor = nil; audioActive = false
        media.audioActivated(false); slot?.release(slotOwner)
        if let uuid { provider.reportCall(with: uuid, endedAt: Date(), reason: reason) }
        await media.disconnect()
        guard notifyOwner, let ended, let oldStamp, let oldClient else { return }
        do {
            try await oldClient.assertCurrent(oldStamp); _ = try await oldClient.me(); try await oldClient.assertCurrent(oldStamp)
            switch ended {
            case .conversation(let value):
                let actual = try await oldClient.activeCall(conversation: value.data.conversationId)
                try await oldClient.assertCurrent(oldStamp)
                if let actual, actual.id == value.data.id, actual.canEnd { try await oldClient.endCall(actual) }
            case .phone(let value):
                let actual = try await oldClient.phoneCall(value.data.id); try await oldClient.assertCurrent(oldStamp)
                if actual.activeOnThisDevice && actual.canEnd { _ = try await oldClient.endPhone(actual.id) }
            }
        } catch { /* Local termination is immediate; owner uncertainty is not retried. */ }
    }
}
