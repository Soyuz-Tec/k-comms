import Combine
import Foundation
import LiveKit

@MainActor final class AppModel: ObservableObject {
    @Published private(set) var session: SignedInMember?
    @Published private(set) var me: Me?
    @Published private(set) var conversations: [Conversation] = []
    @Published private(set) var directory: [Person] = []
    @Published private(set) var directoryCursor: String?
    @Published private(set) var selectedConversation: Conversation?
    @Published private(set) var messages: [Message] = []
    @Published private(set) var senderLabels: [String: SenderLabel] = [:]
    @Published private(set) var pendingMessages: [PendingMessage] = []
    @Published private(set) var meetings: [Meeting] = []
    @Published private(set) var activeCall: Call?
    @Published private(set) var availableCall: Call?
    @Published private(set) var mfaChallenge: MfaChallenge?
    @Published private(set) var messageHasMore = false
    @Published private(set) var hasEarlierMessages = false
    @Published private(set) var busy = false
    @Published private(set) var restoring = true
    @Published private(set) var connectionLabel = "Offline"
    @Published var statusMessage: String?
    @Published var serverInput = ""
    let media = CallMedia()
    private let callSlot = NativeCallSlot()
    private let callOwner = UUID()
    lazy var phone = PhoneModel(slot: callSlot)
    private let callKit = CallKitBridge()
    private let realtime = PhoenixRealtime()
    private var api: ApiClient?
    private var accountGeneration: UInt64 = 0
    private var selectionGeneration: UInt64 = 0
    private var directoryGeneration: UInt64 = 0
    private var workspaceGeneration: UInt64 = 0
    private var replayGeneration: UInt64 = 0
    private var callGeneration: UInt64 = 0
    private var replay = MessageReplay()
    private var olderBefore: Int64?
    private var challengeExpires: Date?
    private var challengeDeadline: TimeInterval?
    private var pendingCall: (call: Call, stamp: IdentityStamp, account: UInt64)?
    private var callLease: AuthorityLease?
    private var callMonitor: Task<Void, Never>?
    private var callWatchdog: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reloadTask: Task<Void, Never>?
    private var foreground = true
    private var osAudioActive = false
    var hasWorkspaceAccess: Bool { me?.user.hasWorkspaceAccess == true }

    init() {
        callKit.onJoin = { [weak self] systemCall in
            guard let self, case .conversation(let call) = systemCall else { throw NativeClientError.sessionChanged }; try await self.joinAdmittedCall(call)
        }
        callKit.onLeave = { [weak self] in await self?.stopCall() }
        callKit.onMute = { [weak self] muted in
            guard let self else { throw NativeClientError.sessionChanged }
            try await self.validateCallAuthority(); try await self.media.setMicrophone(!muted)
        }
        callKit.onAudioActivated = { [weak self] active in
            guard let self else { return }; self.osAudioActive = active
            if !active { self.media.audioActivated(false); return }
            guard self.pendingCall != nil else { return }
            let account = self.accountGeneration; let flight = self.callGeneration
            Task {
                do { try await self.validateCallAuthority(); guard self.isCurrentCall(account, flight) else { return }; self.media.audioActivated(self.osAudioActive) }
                catch { guard self.isCurrentCall(account, flight) else { return }; await self.stopCall(); self.show(error) }
            }
        }
        media.onConnectionChanged = { [weak self] in
            guard let self, self.pendingCall != nil else { return }
            Task { await self.revalidateCallIfConnected() }
        }
        phone.onUnauthorized = { [weak self] in Task { await self?.refreshWorkspace() } }
        Task { await restore() }
    }
    func restore() async {
        let expected = accountGeneration
        restoring = true; defer { if expected == accountGeneration { restoring = false } }
        do {
            guard let credential = try KeychainCredentialVault().load() else { return }
            serverInput = credential.serverOrigin
            let client = try ApiClient(origin: credential.serverOrigin); api = client
            let identity = try await client.me()
            let current = await client.currentSession()
            guard expected == accountGeneration, api === client else { return }
            session = current.map(SignedInMember.init); updateOwner(identity)
            await refreshWorkspace()
        } catch { guard expected == accountGeneration else { return }; await handle(error) }
    }
    func signIn(tenant: String, email: String, password: String) async {
        guard !busy else { return }; busy = true; restoring = false
        accountGeneration &+= 1; let expected = accountGeneration
        defer { if expected == accountGeneration { busy = false } }
        clearContent(); mfaChallenge = nil; challengeExpires = nil; challengeDeadline = nil; statusMessage = nil
        let old = api; api = nil; session = nil; me = nil
        await stopCall()
        if let old { _ = await old.logout() }
        guard expected == accountGeneration else { return }
        do {
            let client = try ApiClient(origin: serverInput); api = client
            let result = try await client.passwordSignIn(tenant: tenant, email: email, password: password)
            guard expected == accountGeneration else { return }
            switch result {
            case .mfa(let challenge):
                guard challenge.expiresIn > 0 else { throw NativeClientError.invalidResponse }
                mfaChallenge = challenge; challengeExpires = Date().addingTimeInterval(TimeInterval(challenge.expiresIn))
                challengeDeadline = ProcessInfo.processInfo.systemUptime + TimeInterval(challenge.expiresIn)
            case .session:
                let identity = try await client.me(); let current = await client.currentSession()
                guard expected == accountGeneration, api === client else { return }; session = current.map(SignedInMember.init); updateOwner(identity); await refreshWorkspace()
            }
        } catch { guard expected == accountGeneration else { return }; await handle(error) }
    }
    func verifyMfa(_ code: String) async {
        guard !busy, let client = api, let challenge = mfaChallenge else { return }
        guard let challengeExpires, challengeExpires > Date(), let challengeDeadline, challengeDeadline > ProcessInfo.processInfo.systemUptime else {
            mfaChallenge = nil; self.challengeExpires = nil; self.challengeDeadline = nil; statusMessage = "Verification expired. Sign in again."; return
        }
        busy = true; let expected = accountGeneration; defer { if expected == accountGeneration { busy = false } }
        do {
            _ = try await client.completeMfa(challenge: challenge.challengeToken, code: code)
            guard expected == accountGeneration else { return }
            let identity = try await client.me(); let current = await client.currentSession()
            guard expected == accountGeneration, api === client else { return }
            session = current.map(SignedInMember.init); updateOwner(identity); mfaChallenge = nil; self.challengeExpires = nil; self.challengeDeadline = nil; await refreshWorkspace()
        } catch { guard expected == accountGeneration else { return }; await handle(error) }
    }
    func cancelMfa() async { await logout() }
    func logout() async {
        accountGeneration &+= 1; let expected = accountGeneration; let old = api
        clearContent(); api = nil; session = nil; me = nil; mfaChallenge = nil; challengeExpires = nil; challengeDeadline = nil; busy = true; restoring = false
        defer { if expected == accountGeneration { busy = false } }
        async let remoteRevocation = old?.logout() ?? true
        await stopCall()
        let revoked = await remoteRevocation
        guard expected == accountGeneration else { return }
        statusMessage = revoked ? "Signed out." : "Signed out locally. Server revocation could not be confirmed; revoke this device from another session."
    }
    private func clearContent() {
        selectionGeneration &+= 1; directoryGeneration &+= 1; replayGeneration &+= 1; workspaceGeneration &+= 1
        realtime.close(); reconnectTask?.cancel(); reloadTask?.cancel(); reconnectTask = nil; reloadTask = nil
        conversations = []; directory = []; directoryCursor = nil; selectedConversation = nil
        replay.reset(); messages = []; senderLabels = [:]; pendingMessages = []; meetings = []; availableCall = nil
        messageHasMore = false; hasEarlierMessages = false; olderBefore = nil; connectionLabel = "Offline"
        phone.clear()
    }
    func refreshWorkspace() async {
        guard let client = api, session != nil else { return }; let expected = accountGeneration
        do {
            let identity = try await client.me(); let rooms = try await client.conversations()
            let current = await client.currentSession()
            guard expected == accountGeneration, api === client else { return }
            updateOwner(identity); session = current.map(SignedInMember.init); conversations = rooms
            if hasWorkspaceAccess { phone.attach(client) }
            else { clearWorkspaceContent() }
            if let selectedConversation, !rooms.contains(where: { $0.id == selectedConversation.id }) {
                selectionGeneration &+= 1; self.selectedConversation = nil; replay.reset(); messages = []; senderLabels = [:]; pendingMessages = []
            }
            if selectedConversation != nil { await catchUp() }
            await openRealtime()
        } catch { guard expected == accountGeneration else { return }; await handle(error) }
    }
    func searchPeople(_ query: String, more: Bool = false) async {
        guard hasWorkspaceAccess, let client = api else { return }; directoryGeneration &+= 1; let expected = directoryGeneration; let account = accountGeneration; let workspace = workspaceGeneration
        do {
            let page = try await client.directory(query: query, cursor: more ? directoryCursor : nil)
            guard expected == directoryGeneration, account == accountGeneration, workspace == workspaceGeneration, hasWorkspaceAccess else { return }
            if more {
                let ids = Set(directory.map(\.id)); directory.append(contentsOf: page.data.filter { !ids.contains($0.id) })
            } else { directory = page.data }
            directoryCursor = page.page.nextCursor
        } catch { guard expected == directoryGeneration, account == accountGeneration, workspace == workspaceGeneration, hasWorkspaceAccess else { return }; directory = []; directoryCursor = nil; await handle(error) }
    }
    func openDirect(_ person: Person) async {
        guard hasWorkspaceAccess, let client = api else { return }; let expected = accountGeneration; let workspace = workspaceGeneration
        do { let room = try await client.directConversation(person: person.id); guard expected == accountGeneration, workspace == workspaceGeneration, hasWorkspaceAccess else { return }; await select(room); await refreshWorkspace() }
        catch { guard expected == accountGeneration, workspace == workspaceGeneration, hasWorkspaceAccess else { return }; await handle(error) }
    }
    func createGroup(title: String, members: Set<String>) async {
        guard hasWorkspaceAccess, let client = api, !members.isEmpty else { return }; let expected = accountGeneration; let workspace = workspaceGeneration
        do { let room = try await client.createGroup(title: title, members: members.sorted()); guard expected == accountGeneration, workspace == workspaceGeneration, hasWorkspaceAccess else { return }; await select(room); await refreshWorkspace() }
        catch { guard expected == accountGeneration, workspace == workspaceGeneration, hasWorkspaceAccess else { return }; await handle(error) }
    }
    func select(_ conversation: Conversation?) async {
        selectionGeneration &+= 1; selectedConversation = conversation; replay.reset(); messages = []; senderLabels = [:]; availableCall = nil
        messageHasMore = false; hasEarlierMessages = false; olderBefore = nil; statusMessage = nil
        if conversation != nil { await catchUp() }
        await openRealtime()
    }
    func loadMore() async { await catchUp(reconcileVisible: false) }
    func catchUp(reconcileVisible: Bool = true) async {
        guard let client = api, let selected = selectedConversation, let member = session else { return }
        let expected = selectionGeneration; let account = accountGeneration
        replayGeneration &+= 1; let flight = replayGeneration
        do {
            let lower = reconcileVisible ? (messages.first.map { max(0, $0.conversationSequence - 1) } ?? max(0, selected.latestSequence - 500)) : replay.forwardCursor
            var after = lower; var pages: [MessagePage] = []; var more = false
            repeat {
                let page = try await client.messages(conversation: selected.id, after: after)
                guard expected == selectionGeneration, account == accountGeneration, flight == replayGeneration else { return }
                guard !page.page.resetRequired, page.data.allSatisfy({ $0.conversationSequence > after }),
                      !page.page.hasMore || (page.page.nextAfterSequence ?? after) > after else { throw NativeClientError.replayDidNotAdvance }
                pages.append(page); after = max(after, page.page.nextAfterSequence ?? page.data.map(\.conversationSequence).max() ?? after); more = page.page.hasMore
            } while more && pages.count < 25
            var updated = replay
            let covered = more ? after : max(after, replay.cursor)
            try updated.reconcile(pages, after: lower, through: covered, conversation: selected.id, tenant: member.tenant.id)
            let labels = try await client.senderLabels(conversation: selected.id, messageIds: updated.sorted.map(\.id))
            guard expected == selectionGeneration, account == accountGeneration, flight == replayGeneration else { return }
            try updated.replaceLabels(labels); replay = updated; messages = updated.sorted; senderLabels = updated.labels; messageHasMore = more
            olderBefore = nil; hasEarlierMessages = (messages.first?.conversationSequence ?? 0) > 1
            let call = try await client.activeCall(conversation: selected.id)
            guard expected == selectionGeneration, account == accountGeneration, flight == replayGeneration else { return }; availableCall = call
        } catch { guard expected == selectionGeneration, account == accountGeneration, flight == replayGeneration else { return }; await handle(error) }
    }
    func loadEarlier() async {
        guard let client = api, let selected = selectedConversation, let member = session,
              let earliest = messages.first?.conversationSequence else { return }
        let expected = selectionGeneration; let account = accountGeneration
        replayGeneration &+= 1; let flight = replayGeneration
        do {
            let before = olderBefore ?? earliest; let lower = max(0, before - 501)
            var after = lower; var pages: [MessagePage] = []; var more = false
            repeat {
                let page = try await client.messages(conversation: selected.id, after: after, before: before)
                guard expected == selectionGeneration, account == accountGeneration, flight == replayGeneration else { return }
                guard page.data.allSatisfy({ $0.conversationSequence > after && $0.conversationSequence < before }),
                      !page.page.hasMore || (page.page.nextAfterSequence ?? after) > after else { throw NativeClientError.replayDidNotAdvance }
                pages.append(page); after = max(after, page.page.nextAfterSequence ?? after); more = page.page.hasMore
            } while more && pages.count < 10
            var updated = replay
            try updated.reconcile(pages, after: lower, through: before - 1, conversation: selected.id, tenant: member.tenant.id, historical: true)
            let labels = try await client.senderLabels(conversation: selected.id, messageIds: updated.sorted.map(\.id))
            guard expected == selectionGeneration, account == accountGeneration, flight == replayGeneration else { return }
            try updated.replaceLabels(labels); replay = updated; messages = updated.sorted; senderLabels = updated.labels
            olderBefore = lower + 1; hasEarlierMessages = lower > 0
            if pages.allSatisfy({ $0.data.isEmpty }) { statusMessage = "No retained messages in this earlier window. Continue backward to check older history." }
        } catch { guard expected == selectionGeneration, account == accountGeneration, flight == replayGeneration else { return }; await handle(error) }
    }
    func markVisibleRead() async {
        guard foreground, let client = api, let selected = selectedConversation, let sequence = messages.last?.conversationSequence else { return }
        let account = accountGeneration
        do { try await client.read(conversation: selected.id, sequence: sequence) }
        catch { guard account == accountGeneration else { return }; await handle(error) }
    }
    func send(_ body: String) async {
        guard let client = api, let selected = selectedConversation, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let account = accountGeneration
        do {
            let pending = PendingMessage(conversation: selected.id, body: body, stamp: try await client.stamp())
            guard account == accountGeneration, api === client else { return }
            pendingMessages.append(pending); await retry(pending)
        } catch { guard account == accountGeneration, api === client else { return }; await handle(error) }
    }
    func retry(_ pending: PendingMessage) async {
        guard let client = api, pendingMessages.contains(where: { $0.id == pending.id }) else { return }; let account = accountGeneration
        do {
            let value = try await client.send(pending)
            guard account == accountGeneration else { return }
            guard value.conversationId == pending.conversation, value.tenantId == pending.stamp.identity.tenant, value.clientMessageId == pending.id else { throw NativeClientError.invalidResponse }
            pendingMessages.removeAll { $0.id == pending.id }
            if selectedConversation?.id == pending.conversation {
                await catchUp()
            }
        } catch {
            guard account == accountGeneration else { return }
            if let error = error as? NativeApiError, [400, 401, 403, 404, 409, 422].contains(error.status) { pendingMessages.removeAll { $0.id == pending.id } }
            await handle(error)
        }
    }
    func discard(_ pending: PendingMessage) { pendingMessages.removeAll { $0.id == pending.id } }
    func edit(_ message: Message, body: String) async {
        guard let client = api, message.senderUserId == session?.user.id, message.tenantId == session?.tenant.id,
              message.conversationId == selectedConversation?.id, message.status == "active" else { return }
        let account = accountGeneration; let selection = selectionGeneration
        do { _ = try await client.editMessage(message, body: body); guard account == accountGeneration, selection == selectionGeneration else { return }; await catchUp() }
        catch { guard account == accountGeneration, selection == selectionGeneration else { return }; await handle(error) }
    }
    func delete(_ message: Message) async {
        guard let client = api, message.senderUserId == session?.user.id, message.tenantId == session?.tenant.id,
              message.conversationId == selectedConversation?.id, message.status == "active" else { return }
        let account = accountGeneration; let selection = selectionGeneration
        do { try await client.deleteMessage(message); guard account == accountGeneration, selection == selectionGeneration else { return }; await catchUp() }
        catch { guard account == accountGeneration, selection == selectionGeneration else { return }; await handle(error) }
    }
    func refreshMeetings() async {
        guard hasWorkspaceAccess, let client = api else { return }; let expected = accountGeneration; let workspace = workspaceGeneration
        do {
            let now = Date(); let values = try await client.meetings(from: now.addingTimeInterval(-86_400), through: now.addingTimeInterval(7 * 86_400))
            guard expected == accountGeneration, workspace == workspaceGeneration, hasWorkspaceAccess else { return }; meetings = values
        } catch { guard expected == accountGeneration, workspace == workspaceGeneration, hasWorkspaceAccess else { return }; meetings = []; await handle(error) }
    }
    func createMeeting(conversation: String, title: String, start: Date, duration: Int) async {
        guard hasWorkspaceAccess, let client = api else { return }; let account = accountGeneration; let workspace = workspaceGeneration
        do { _ = try await client.createMeeting(conversation: conversation, title: title, start: start, duration: duration); guard account == accountGeneration, workspace == workspaceGeneration, hasWorkspaceAccess else { return }; await refreshMeetings() }
        catch { guard account == accountGeneration, workspace == workspaceGeneration, hasWorkspaceAccess else { return }; await handle(error) }
    }
    func cancelMeeting(_ meeting: Meeting) async {
        guard hasWorkspaceAccess, let client = api, meeting.canManage else { return }; let account = accountGeneration; let workspace = workspaceGeneration
        do { _ = try await client.cancelMeeting(meeting); guard account == accountGeneration, workspace == workspaceGeneration, hasWorkspaceAccess else { return }; await refreshMeetings() }
        catch { guard account == accountGeneration, workspace == workspaceGeneration, hasWorkspaceAccess else { return }; await handle(error) }
    }
    func startCall(video: Bool, joinExisting: Bool = false) async {
        guard foreground, activeCall == nil, pendingCall == nil, let client = api, let conversation = selectedConversation else { return }
        guard callSlot.acquire(callOwner) else { statusMessage = "Leave the current call before starting another."; return }
        callGeneration &+= 1; let flight = callGeneration; let expected = accountGeneration
        do {
            try await CallMedia.requestPermissions(video: video); guard foreground, flight == callGeneration, expected == accountGeneration else { throw NativeClientError.sessionChanged }
            let identity = try await client.me()
            guard foreground, flight == callGeneration, expected == accountGeneration else { throw NativeClientError.sessionChanged }
            guard video ? identity.capabilities.allowVideoCalls : identity.capabilities.allowAudioCalls else { throw NativeApiError(status: 403, code: "call_disabled") }
            let admission: CallAdmission
            if joinExisting, let availableCall { admission = try await client.joinCall(availableCall) }
            else { admission = try await client.startCall(conversation: conversation.id, video: video) }
            guard foreground, flight == callGeneration, expected == accountGeneration else { throw NativeClientError.sessionChanged }
            try await prepareCall(admission, client: client, account: expected, flight: flight)
        } catch { guard expected == accountGeneration, flight == callGeneration else { return }; await stopCall(); await handle(error) }
    }
    func startMeeting(_ meeting: Meeting, occurrence: Meeting.Occurrence, video: Bool) async {
        guard hasWorkspaceAccess, foreground, activeCall == nil, let client = api else { return }; let expected = accountGeneration; let workspace = workspaceGeneration
        guard callSlot.acquire(callOwner) else { statusMessage = "Leave the current call before starting another."; return }
        callGeneration &+= 1; let flight = callGeneration
        do {
            try await CallMedia.requestPermissions(video: video); guard foreground, flight == callGeneration, expected == accountGeneration, workspace == workspaceGeneration, hasWorkspaceAccess else { throw NativeClientError.sessionChanged }
            let admission = try await client.startMeeting(meeting, occurrence: occurrence, video: video)
            guard foreground, flight == callGeneration, expected == accountGeneration, workspace == workspaceGeneration, hasWorkspaceAccess else { throw NativeClientError.sessionChanged }
            try await prepareCall(admission, client: client, account: expected, flight: flight, workspace: workspace)
        } catch { guard expected == accountGeneration, flight == callGeneration else { return }; await stopCall(); await handle(error) }
    }
    private func prepareCall(_ admission: CallAdmission, client: ApiClient, account: UInt64, flight: UInt64, workspace: UInt64? = nil) async throws {
        let stamp = try await client.stamp(); guard foreground, flight == callGeneration, account == accountGeneration, api === client else { throw NativeClientError.sessionChanged }
        if let workspace { guard workspace == workspaceGeneration, hasWorkspaceAccess else { throw NativeClientError.workspaceUnavailable } }
        pendingCall = (admission.data, stamp, account); activeCall = admission.data
        let now = Date(); callLease = AuthorityLease(stamp: stamp, credentialExpires: now.addingTimeInterval(TimeInterval(admission.credential.expiresIn)), lastObserved: now)
        try await callKit.begin(admission.data)
    }
    private func joinAdmittedCall(_ call: Call) async throws {
        guard let client = api, let bound = pendingCall, bound.call.id == call.id, bound.account == accountGeneration else { throw NativeClientError.sessionChanged }
        let flight = callGeneration
        try await client.assertCurrent(bound.stamp)
        guard isCurrentCall(bound.account, flight) else { throw NativeClientError.sessionChanged }
        let admission = try await client.joinCall(call)
        guard isCurrentCall(bound.account, flight), pendingCall?.call.id == call.id,
              admission.data.id == call.id, admission.data.conversationId == call.conversationId else { throw NativeClientError.sessionChanged }
        let now = Date(); callLease = AuthorityLease(stamp: bound.stamp, credentialExpires: now.addingTimeInterval(TimeInterval(admission.credential.expiresIn)), lastObserved: now)
        try await media.connect(admission) { [weak self] in
            guard let self, self.isCurrentCall(bound.account, flight) else { throw NativeClientError.sessionChanged }; try await self.assertCallLease()
        }
        try await validateCallAuthority(); guard isCurrentCall(bound.account, flight) else { throw NativeClientError.sessionChanged }; startCallMonitors(); await openRealtime()
    }
    private func isCurrentCall(_ account: UInt64, _ flight: UInt64) -> Bool { foreground && account == accountGeneration && flight == callGeneration }
    private func assertCallLease() async throws {
        guard let client = api, let bound = pendingCall, bound.account == accountGeneration,
              let expiry = Wire.date(bound.call.expiresAt), expiry > Date(),
              let callLease, callLease.valid(stamp: bound.stamp) else { throw NativeClientError.sessionChanged }
        let flight = callGeneration; try await client.assertCurrent(bound.stamp)
        guard isCurrentCall(bound.account, flight) else { throw NativeClientError.sessionChanged }
        if callLease.needsRevalidation() { try await validateCallAuthority() }
        guard isCurrentCall(bound.account, flight), pendingCall?.call.id == bound.call.id else { throw NativeClientError.sessionChanged }
    }
    private func validateCallAuthority() async throws {
        guard let client = api, let bound = pendingCall, bound.account == accountGeneration,
              let callLease, callLease.credentialIsCurrent() else { throw NativeClientError.sessionChanged }
        let flight = callGeneration; try await client.assertCurrent(bound.stamp)
        guard isCurrentCall(bound.account, flight) else { throw NativeClientError.sessionChanged }
        async let current = client.me()
        async let call = client.activeCall(conversation: bound.call.conversationId)
        async let participants = client.participants(bound.call)
        let (identity, actual, admitted) = try await (current, call, participants)
        try await client.assertCurrent(bound.stamp)
        guard isCurrentCall(bound.account, flight), api === client, pendingCall?.call.id == bound.call.id,
              let actual, actual.id == bound.call.id, actual.status == "active",
              let expiry = Wire.date(actual.expiresAt), expiry > Date(),
              admitted.contains(where: { $0.userId == bound.stamp.identity.user && $0.status == "admitted" }),
              actual.isVideo ? identity.capabilities.allowVideoCalls : identity.capabilities.allowAudioCalls else { throw NativeApiError(status: 403, code: "call_access_ended") }
        updateOwner(identity)
        if !hasWorkspaceAccess { clearWorkspaceContent() }
        activeCall = actual; self.callLease?.observe()
    }
    private func revalidateCallIfConnected() async {
        guard pendingCall != nil else { return }; let account = accountGeneration; let flight = callGeneration
        do {
            try await validateCallAuthority(); guard isCurrentCall(account, flight) else { return }
            if media.room?.connectionState == .connected { media.audioActivated(osAudioActive) }
        } catch { guard isCurrentCall(account, flight) else { return }; await stopCall(); show(error) }
    }
    private func startCallMonitors() {
        let account = accountGeneration; let flight = callGeneration
        callMonitor?.cancel(); callWatchdog?.cancel()
        callMonitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 5_000_000_000); guard let self, self.isCurrentCall(account, flight) else { return }; try await self.validateCallAuthority() }
                catch { guard !Task.isCancelled, let self, self.isCurrentCall(account, flight) else { return }; await self.stopCall(); self.show(error); return }
            }
        }
        callWatchdog = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                guard let self, self.isCurrentCall(account, flight), let bound = self.pendingCall else { return }
                if self.callLease?.valid(stamp: bound.stamp) != true {
                    self.media.audioActivated(false); await self.stopCall(); self.statusMessage = "Call disconnected because current access could not be confirmed."; return
                }
            }
        }
    }
    func toggleMicrophone() async {
        let account = accountGeneration; let flight = callGeneration
        do { try await validateCallAuthority(); guard isCurrentCall(account, flight) else { return }; try await media.setMicrophone(!media.microphoneEnabled) }
        catch { guard isCurrentCall(account, flight) else { return }; await stopCall(); await handle(error) }
    }
    func toggleCamera() async {
        let account = accountGeneration; let flight = callGeneration
        do { try await validateCallAuthority(); guard isCurrentCall(account, flight) else { return }; try await media.setCamera(!media.cameraEnabled) }
        catch { guard isCurrentCall(account, flight) else { return }; await handle(error) }
    }
    func leaveCall() async { await callKit.leave() }
    func endCallForEveryone() async {
        guard let client = api, let call = activeCall, call.canEnd else { return }; let expected = accountGeneration; let flight = callGeneration
        do { try await client.endCall(call); guard isCurrentCall(expected, flight) else { return }; await stopCall() }
        catch { guard isCurrentCall(expected, flight) else { return }; await handle(error) }
    }
    private func stopCall() async {
        callGeneration &+= 1
        pendingCall = nil; activeCall = nil; callLease = nil
        callMonitor?.cancel(); callWatchdog?.cancel(); callMonitor = nil; callWatchdog = nil
        osAudioActive = false; callKit.terminate(); await media.disconnect()
        callSlot.release(callOwner)
    }
    func sceneActive(_ active: Bool) async {
        foreground = active
        phone.setForeground(active)
        if active { if session != nil { await refreshWorkspace() } }
        else { realtime.close(); reconnectTask?.cancel(); await stopCall(); await phone.stop() }
    }
    private func openRealtime() async {
        guard foreground, let client = api, session != nil else { return }; let account = accountGeneration; let selection = selectionGeneration
        do {
            let stamp = try await client.stamp()
            guard account == accountGeneration, selection == selectionGeneration else { return }
            try await realtime.connect(api: client, stamp: stamp, conversation: selectedConversation?.id, cursor: replay.cursor, call: activeCall) { [weak self] signal in
                guard let self, account == self.accountGeneration, selection == self.selectionGeneration else { return }
                switch signal {
                case .connected: self.connectionLabel = "Live"
                case .disconnected: self.connectionLabel = "Reconnecting"; self.scheduleReconnect(account: account)
                case .callChanged:
                    Task {
                        guard account == self.accountGeneration, selection == self.selectionGeneration else { return }
                        await self.revalidateCallIfConnected(); guard account == self.accountGeneration else { return }; await self.catchUp()
                    }
                case .contentChanged: self.scheduleReload(account: account)
                case .authorityChanged:
                    let flight = self.callGeneration
                    self.clearContent(); self.media.audioActivated(false)
                    Task {
                        guard account == self.accountGeneration else { return }
                        if flight == self.callGeneration { await self.stopCall() }
                        guard account == self.accountGeneration else { return }; await self.refreshWorkspace()
                    }
                case .phoneChanged:
                    Task { guard account == self.accountGeneration else { return }; await self.phone.refresh(); guard account == self.accountGeneration else { return }; await self.phone.revalidateIfConnected() }
                }
            }
            guard account == accountGeneration, selection == selectionGeneration else { return }
            if connectionLabel != "Live" { connectionLabel = "Connecting" }
        } catch { guard account == accountGeneration, selection == selectionGeneration else { return }; connectionLabel = "Reconnecting"; scheduleReconnect(account: account) }
    }
    private func scheduleReload(account: UInt64) {
        guard reloadTask == nil else { return }
        reloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, let self, account == self.accountGeneration else { return }
            self.reloadTask = nil
            guard let client = self.api else { return }
            do {
                let identity = try await client.me(); let rooms = try await client.conversations()
                guard account == self.accountGeneration else { return }; self.updateOwner(identity); self.conversations = rooms
                if !self.hasWorkspaceAccess { self.clearWorkspaceContent() }
                if let selected = self.selectedConversation, !rooms.contains(where: { $0.id == selected.id }) { await self.select(nil) }
                else { await self.catchUp() }
            } catch { guard account == self.accountGeneration else { return }; await self.handle(error) }
        }
    }
    private func scheduleReconnect(account: UInt64) {
        guard reconnectTask == nil, foreground else { return }
        reconnectTask = Task { [weak self] in
            for delay in [1, 2, 5, 10, 15] {
                do { try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000) } catch { return }
                guard let self, self.foreground, account == self.accountGeneration, let client = self.api else { return }
                do {
                    _ = try await client.me(); await self.catchUp()
                    self.reconnectTask = nil; await self.openRealtime(); return
                } catch {
                    if let denied = error as? NativeApiError, denied.removesCachedContent { await self.handle(error); self.reconnectTask = nil; return }
                }
            }
            guard let self, account == self.accountGeneration else { return }; self.reconnectTask = nil; self.connectionLabel = "Offline — refresh to reconnect"
        }
    }
    private func handle(_ error: Error) async {
        let account = accountGeneration; let bound = api; let current = await bound?.currentSession()
        guard account == accountGeneration, api === bound else { return }
        if session != nil && current == nil {
            accountGeneration &+= 1; clearContent(); api = nil; session = nil; me = nil; mfaChallenge = nil; challengeExpires = nil; challengeDeadline = nil; busy = false
            let invalidated = accountGeneration
            await stopCall(); guard invalidated == accountGeneration else { return }; show(NativeApiError(status: 401, code: "sign_in_required")); return
        }
        if let changed = error as? NativeClientError, case .sessionChanged = changed { return }
        if let changed = error as? NativeClientError, case .workspaceUnavailable = changed {
            let identity = try? await bound?.me()
            guard account == accountGeneration, api === bound else { return }
            if let identity { updateOwner(identity) }
            clearWorkspaceContent(); show(error); return
        }
        if let changed = error as? NativeClientError, case .replayPrivacyBudgetExceeded = changed {
            clearContent(); await stopCall(); guard account == accountGeneration, api === bound else { return }
        }
        if let denied = error as? NativeApiError, denied.removesCachedContent {
            clearContent(); await stopCall()
            guard account == accountGeneration, api === bound else { return }
            let stillCurrent = await bound?.currentSession()
            guard account == accountGeneration, api === bound else { return }
            if stillCurrent == nil { session = nil; me = nil; api = nil }
        }
        show(error)
    }
    private func updateOwner(_ identity: Me) {
        // Actor replies can arrive at the UI after a newer projection was applied.
        guard (identity.user.version ?? 0) >= (me?.user.version ?? 0) else { return }
        if hasWorkspaceAccess != identity.user.hasWorkspaceAccess { workspaceGeneration &+= 1 }
        me = identity
        if !hasWorkspaceAccess { clearWorkspaceContent() }
    }
    private func clearWorkspaceContent() {
        workspaceGeneration &+= 1; directoryGeneration &+= 1; directory = []; directoryCursor = nil; meetings = []; phone.clear()
    }
    private func show(_ error: Error) {
        if let known = error as? NativeApiError { statusMessage = known.errorDescription }
        else if let known = error as? NativeClientError { statusMessage = known.errorDescription }
        else if error is URLError { statusMessage = "The network is unavailable. Retry when connected." }
        else { statusMessage = "This action could not be completed. Try again." }
    }
}
