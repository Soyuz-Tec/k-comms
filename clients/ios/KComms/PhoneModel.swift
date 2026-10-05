import Combine
import Foundation
import LiveKit

@MainActor final class PhoneModel: ObservableObject {
    @Published private(set) var configuration: PhoneConfiguration?
    @Published private(set) var history: [PhoneCall] = []
    @Published private(set) var nextCursor: String?
    @Published private(set) var active: PhoneCall?
    @Published private(set) var receipts: [PhoneControlReceipt] = []
    @Published private(set) var capabilities: [String: PhoneCapability] = [:]
    @Published private(set) var busy = false
    @Published var notice: String?
    let media = CallMedia()
    var onUnauthorized: (@MainActor () -> Void)?
    private let systemCall = CallKitBridge()
    private let slot: NativeCallSlot
    private let owner = UUID()
    private var api: ApiClient?
    private var generation: UInt64 = 0
    private var readGeneration: UInt64 = 0
    private var callGeneration: UInt64 = 0
    private var foreground = true
    private var lease: AuthorityLease?
    private var monitor: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var osAudioActive = false
    private var dialAttempt: (destination: String, key: String)?
    private var toneAttempt: (digit: String, key: String, receipt: PhoneControlReceipt?)?
    var hasPendingTone: Bool { toneAttempt != nil }
    var canSendTone: Bool { active?.status == "answered" && active?.activeOnThisDevice == true && capabilities["dtmf"]?.supported == true && media.room?.connectionState == .connected && !busy && !hasPendingTone }
    init(slot: NativeCallSlot) {
        self.slot = slot
        systemCall.onJoin = { [weak self] descriptor in
            guard let self, case .phone(let call) = descriptor else { throw NativeClientError.sessionChanged }; try await self.joinAdmitted(call)
        }
        systemCall.onLeave = { [weak self] in await self?.stop() }
        systemCall.onMute = { [weak self] muted in guard let self else { throw NativeClientError.sessionChanged }; try await self.validate(); try await self.media.setMicrophone(!muted) }
        systemCall.onAudioActivated = { [weak self] active in
            guard let self else { return }; self.osAudioActive = active
            if !active { self.media.audioActivated(false); return }
            guard self.active != nil else { return }
            let account = self.generation; let flight = self.callGeneration
            Task {
                do { try await self.validate(); guard self.isCurrentCall(account, flight) else { return }; self.media.audioActivated(self.osAudioActive) }
                catch { guard self.isCurrentCall(account, flight) else { return }; await self.stop(); self.show(error) }
            }
        }
        media.onConnectionChanged = { [weak self] in guard let self, self.active != nil else { return }; Task { await self.revalidateIfConnected() } }
    }
    func attach(_ client: ApiClient) { if api !== client { clear(); api = client } }
    func setForeground(_ active: Bool) { foreground = active; if !active { callGeneration &+= 1; media.audioActivated(false) } }
    func clear() {
        generation &+= 1; readGeneration &+= 1; callGeneration &+= 1; api = nil; active = nil; lease = nil
        monitor?.cancel(); watchdog?.cancel(); monitor = nil; watchdog = nil
        configuration = nil; history = []; nextCursor = nil; capabilities = [:]; receipts = []; notice = nil
        dialAttempt = nil; toneAttempt = nil; busy = false; osAudioActive = false
        systemCall.terminate(); let old = media.invalidate(); slot.release(owner)
        Task { await old?.disconnect() }
    }
    func refresh(more: Bool = false) async {
        guard let api else { return }; let account = generation; readGeneration &+= 1; let read = readGeneration
        do {
            async let config = api.phoneConfiguration(); async let caps = api.phoneCapabilities()
            let page = try await api.phoneCalls(cursor: more ? nextCursor : nil)
            let (configuration, capabilities) = try await (config, caps)
            guard account == generation, read == readGeneration else { return }
            self.configuration = configuration; self.capabilities = capabilities
            if more { let ids = Set(history.map(\.id)); history += page.data.filter { !ids.contains($0.id) } }
            else { history = page.data }
            nextCursor = page.page.hasMore ? page.page.nextCursor : nil
            if let active {
                let current = try await api.phoneControls(active.id)
                guard account == generation, read == readGeneration, self.api === api, self.active?.id == active.id else { return }; receipts = current
            }
        } catch { guard account == generation, read == readGeneration else { return }; await handle(error) }
    }
    func dial(_ destination: String) async {
        guard foreground, !busy, active == nil, let api, slot.acquire(owner) else { return }
        callGeneration &+= 1; let flight = callGeneration
        busy = true; let account = generation; defer { if account == generation { busy = false } }
        do {
            guard destination.range(of: "^\\+[1-9][0-9]{7,14}$", options: .regularExpression) != nil else { throw NativeClientError.invalidResponse }
            try await CallMedia.requestPermissions(video: false)
            guard foreground, flight == callGeneration, account == generation else { throw NativeClientError.sessionChanged }
            let config = try await api.phoneConfiguration(); guard foreground, flight == callGeneration, account == generation else { throw NativeClientError.sessionChanged }
            configuration = config; guard config.canCall else { throw NativeApiError(status: 503, code: "phone_unavailable") }
            if dialAttempt?.destination != destination { dialAttempt = (destination, UUID().uuidString) }
            let admission = try await api.dialPhone(destination: destination, key: dialAttempt!.key)
            guard foreground, flight == callGeneration, account == generation else { throw NativeClientError.sessionChanged }; dialAttempt = nil
            try await prepare(admission, account: account, flight: flight)
        } catch { guard account == generation, flight == callGeneration else { return }; await stop(); await handle(error) }
    }
    func admit(_ call: PhoneCall, answer: Bool) async {
        guard foreground, !busy, active == nil, let api, slot.acquire(owner) else { return }
        callGeneration &+= 1; let flight = callGeneration
        busy = true; let account = generation; defer { if account == generation { busy = false } }
        do {
            try await CallMedia.requestPermissions(video: false)
            guard foreground, flight == callGeneration, account == generation else { throw NativeClientError.sessionChanged }
            let fresh = try await api.phoneCall(call.id); guard foreground, flight == callGeneration, account == generation else { throw NativeClientError.sessionChanged }
            guard answer ? fresh.canAnswer : fresh.canJoin else { throw NativeApiError(status: 403, code: "phone_admission_refused") }
            let admission: PhoneAdmission
            if answer { admission = try await api.answerPhone(fresh.id) } else { admission = try await api.joinPhone(fresh.id) }
            guard foreground, flight == callGeneration, account == generation else { throw NativeClientError.sessionChanged }; try await prepare(admission, account: account, flight: flight)
        } catch { guard account == generation, flight == callGeneration else { return }; await stop(); await handle(error) }
    }
    private func prepare(_ admission: PhoneAdmission, account: UInt64, flight: UInt64) async throws {
        guard let api, account == generation, admission.data.isActive, admission.data.activeOnThisDevice, admission.credential.expiresIn > 0 else { throw NativeClientError.invalidResponse }
        let stamp = try await api.stamp()
        guard foreground, flight == callGeneration, account == generation, self.api === api, active == nil else { throw NativeClientError.sessionChanged }
        active = admission.data
        lease = AuthorityLease(stamp: stamp, credentialExpires: Date().addingTimeInterval(TimeInterval(admission.credential.expiresIn)), lastObserved: Date())
        try await systemCall.beginPhone(admission.data)
    }
    private func joinAdmitted(_ call: PhoneCall) async throws {
        guard let api, active?.id == call.id, let bound = lease else { throw NativeClientError.sessionChanged }
        let account = generation; let flight = callGeneration; try await api.assertCurrent(bound.stamp)
        guard isCurrentCall(account, flight) else { throw NativeClientError.sessionChanged }
        let admission = try await api.joinPhone(call.id)
        guard foreground, flight == callGeneration, account == generation, active?.id == call.id, admission.data.id == call.id, admission.data.activeOnThisDevice else { throw NativeClientError.sessionChanged }
        lease = AuthorityLease(stamp: bound.stamp, credentialExpires: Date().addingTimeInterval(TimeInterval(admission.credential.expiresIn)), lastObserved: Date())
        active = admission.data
        try await media.connect(credential: admission.credential, video: false) { [weak self] in
            guard let self, self.isCurrentCall(account, flight) else { throw NativeClientError.sessionChanged }; try await self.assertLease()
        }
        try await validate(); guard isCurrentCall(account, flight) else { throw NativeClientError.sessionChanged }; startMonitors(); await refresh()
    }
    private func isCurrentCall(_ account: UInt64, _ flight: UInt64) -> Bool { foreground && account == generation && flight == callGeneration }
    private func assertLease() async throws {
        guard let api, let lease, let call = active, call.activeOnThisDevice else { throw NativeClientError.sessionChanged }
        let account = generation; let flight = callGeneration; let current = try await api.stamp()
        guard isCurrentCall(account, flight), self.api === api, active?.id == call.id, self.lease?.stamp == lease.stamp,
              lease.valid(stamp: current) else { throw NativeClientError.sessionChanged }
        if lease.needsRevalidation() { try await validate() }
        guard isCurrentCall(account, flight) else { throw NativeClientError.sessionChanged }
    }
    private func validate() async throws {
        guard let api, let active, let bound = lease else { throw NativeClientError.sessionChanged }
        let account = generation; let flight = callGeneration; try await api.assertCurrent(bound.stamp)
        guard isCurrentCall(account, flight) else { throw NativeClientError.sessionChanged }
        async let identity = api.me(); async let actual = api.phoneCall(active.id)
        let (member, current) = try await (identity, actual); try await api.assertCurrent(bound.stamp)
        guard isCurrentCall(account, flight), self.api === api, self.active?.id == active.id, current.isActive, current.activeOnThisDevice,
              member.user.hasWorkspaceAccess, bound.credentialIsCurrent() else { throw NativeApiError(status: 403, code: "phone_access_ended") }
        self.active = current; lease?.observe()
    }
    func revalidateIfConnected() async {
        guard active != nil else { return }
        let account = generation; let flight = callGeneration
        do { try await validate(); guard isCurrentCall(account, flight) else { return }; media.audioActivated(osAudioActive && media.room?.connectionState == .connected) }
        catch { guard isCurrentCall(account, flight) else { return }; await stop(); await handle(error) }
    }
    private func startMonitors() {
        let account = generation; let flight = callGeneration
        monitor?.cancel(); watchdog?.cancel()
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 5_000_000_000); guard let self, self.isCurrentCall(account, flight) else { return }; try await self.validate() }
                catch { guard !Task.isCancelled, let self, self.isCurrentCall(account, flight) else { return }; await self.stop(); await self.handle(error); return }
            }
        }
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                guard let self, let api = self.api, let lease = self.lease else { return }
                let current = try? await api.stamp()
                guard !Task.isCancelled, account == self.generation, flight == self.callGeneration else { return }
                if current.map({ lease.valid(stamp: $0) }) != true {
                    await self.stop(); self.notice = "Phone disconnected because current access expired or could not be confirmed."; return
                }
            }
        }
    }
    func sendTone(_ digit: String) async {
        guard canSendTone, let api, let call = active else { return }; let account = generation; let flight = callGeneration
        busy = true; defer { if account == generation { busy = false } }
        toneAttempt = (digit, UUID().uuidString, nil)
        do {
            try await validate()
            guard isCurrentCall(account, flight) else { return }
            let receipt = try await api.requestTone(call.id, digit: digit, key: toneAttempt!.key)
            guard isCurrentCall(account, flight), active?.id == call.id else { return }; toneAttempt?.receipt = receipt
            guard receipt.authorizesTone(call: call.id) else { notice = "The server did not authorize a new tone. Review the control receipt."; return }
            var result = "submitted"
            do { try await validate(); try await media.sendDtmf(digit) } catch { result = "unknown" }
            guard isCurrentCall(account, flight), active?.id == call.id else { return }
            let completed = try await api.completeTone(call.id, command: receipt.id, status: result)
            guard isCurrentCall(account, flight) else { return }; receipts.insert(completed, at: 0); toneAttempt = nil
            notice = result == "submitted" ? "Tone submitted to the SDK. Carrier delivery is not confirmed." : "Tone delivery is uncertain. Do not repeat it automatically."
        } catch { guard isCurrentCall(account, flight) else { return }; await handle(error) }
    }
    /// This checks the owner receipt only. It never re-emits a possibly submitted tone.
    func reconcilePendingTone() async {
        guard !busy, let api, let call = active else { return }; let account = generation; let flight = callGeneration
        busy = true; defer { if account == generation { busy = false } }
        do {
            if let receipt = toneAttempt?.receipt { let current = try await api.reconcileTone(call.id, command: receipt.id); guard isCurrentCall(account, flight) else { return }; receipts.insert(current, at: 0) }
            else { let current = try await api.phoneControls(call.id); guard isCurrentCall(account, flight) else { return }; receipts = current }
            toneAttempt = nil; notice = "Receipts refreshed. A submitted or uncertain tone is never automatically repeated."
        } catch { guard isCurrentCall(account, flight) else { return }; await handle(error) }
    }
    func toggleMicrophone() async {
        let account = generation; let flight = callGeneration
        do { try await validate(); guard isCurrentCall(account, flight) else { return }; try await media.setMicrophone(!media.microphoneEnabled) }
        catch { guard isCurrentCall(account, flight) else { return }; await stop(); await handle(error) }
    }
    func end() async {
        guard let api, let call = active, call.canEnd else { return }; let account = generation; let flight = callGeneration
        do { _ = try await api.endPhone(call.id); guard isCurrentCall(account, flight) else { return }; await stop(); await refresh() }
        catch { guard isCurrentCall(account, flight) else { return }; await handle(error) }
    }
    func reject(_ call: PhoneCall) async {
        guard let api, call.canAnswer else { return }; let account = generation
        do { _ = try await api.rejectPhone(call.id); guard account == generation else { return }; await refresh() }
        catch { guard account == generation else { return }; await handle(error) }
    }
    func leave() async { await systemCall.leave() }
    func stop() async {
        callGeneration &+= 1; let cleanup = callGeneration
        active = nil; lease = nil; toneAttempt = nil; monitor?.cancel(); watchdog?.cancel(); monitor = nil; watchdog = nil
        systemCall.terminate(); osAudioActive = false; let old = media.invalidate(); await old?.disconnect()
        if cleanup == callGeneration { slot.release(owner) }
    }
    private func handle(_ error: Error) async {
        let account = generation; let bound = api; let current = await bound?.currentSession()
        guard account == generation, api === bound else { return }
        if bound != nil && current == nil { clear(); onUnauthorized?(); show(NativeApiError(status: 401, code: "sign_in_required")); return }
        if let changed = error as? NativeClientError, case .workspaceUnavailable = changed { clear(); onUnauthorized?(); show(error); return }
        if let denied = error as? NativeApiError, denied.removesCachedContent { clear(); if denied.status == 401 { onUnauthorized?() } }
        if let changed = error as? NativeClientError, case .sessionChanged = changed { return }
        show(error)
    }
    private func show(_ error: Error) { notice = (error as? NativeApiError)?.errorDescription ?? (error as? NativeClientError)?.errorDescription ?? "The phone request could not be completed. Refresh before retrying an uncertain action." }
}
