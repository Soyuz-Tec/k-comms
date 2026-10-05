import Foundation

struct PendingMessage: Identifiable, Sendable {
    let id: String
    let conversation: String
    let body: String
    let stamp: IdentityStamp
    init(conversation: String, body: String, stamp: IdentityStamp, id: String = UUID().uuidString) {
        self.id = id; self.conversation = conversation; self.body = body; self.stamp = stamp
    }
}

/// Live socket events invalidate REST history; they never establish newer message revisions.
struct MessageReplay {
    private(set) var cursor: Int64 = 0
    private(set) var messages: [String: Message] = [:]
    private(set) var labels: [String: SenderLabel] = [:]
    private var tombstones: Set<String> = []
    private var redactedAuthors: Set<String> = []
    private var privacyBudgetExceeded = false
    var sorted: [Message] { messages.values.sorted { $0.conversationSequence < $1.conversationSequence } }
    var forwardCursor: Int64 { sorted.last?.conversationSequence ?? cursor }
    mutating func reset() { cursor = 0; messages = [:]; labels = [:]; tombstones = []; redactedAuthors = []; privacyBudgetExceeded = false }
    mutating func accept(_ page: MessagePage, conversation: String, tenant: String, historical: Bool = false, after: Int64? = nil) throws {
        guard !privacyBudgetExceeded else { throw NativeClientError.replayPrivacyBudgetExceeded }
        if page.page.resetRequired { reset() }
        guard page.data.allSatisfy({ $0.conversationId == conversation && $0.tenantId == tenant && $0.conversationSequence > 0 }) else {
            throw NativeClientError.invalidResponse
        }
        if !historical && page.page.hasMore {
            let requested = after ?? cursor
            guard let next = page.page.nextAfterSequence, next > requested,
                  next >= (page.data.map(\.conversationSequence).max() ?? requested) else { throw NativeClientError.replayDidNotAdvance }
        }
        for message in page.data { merge(message) }
        guard !privacyBudgetExceeded else { throw NativeClientError.replayPrivacyBudgetExceeded }
        var sidecar = labels
        for label in page.included?.senderLabels ?? [] { sidecar[label.id] = label }
        try replaceLabels(Array(sidecar.values))
        if !historical { cursor = max(cursor, max(page.data.map(\.conversationSequence).max() ?? cursor, page.page.nextAfterSequence ?? cursor)) }
        let window = historical ? Array(sorted.prefix(500)) : Array(sorted.suffix(500))
        let retained = Set(window.map(\.id)); messages = messages.filter { retained.contains($0.key) }
        let senderIds = Set(messages.values.map(\.senderUserId)); labels = labels.filter { senderIds.contains($0.key) }
    }
    /// A complete REST range replaces missing retained rows too. Socket hints never do.
    mutating func reconcile(_ pages: [MessagePage], after: Int64, through: Int64, conversation: String, tenant: String, historical: Bool = false) throws {
        guard !privacyBudgetExceeded else { throw NativeClientError.replayPrivacyBudgetExceeded }
        var observed: [String: Message] = [:]
        for page in pages {
            guard !page.page.resetRequired, page.data.allSatisfy({ $0.conversationId == conversation && $0.tenantId == tenant && $0.conversationSequence > after }) else {
                throw NativeClientError.invalidResponse
            }
            for message in page.data { observed[message.id] = message }
        }
        for (id, message) in messages where message.conversationSequence > after && message.conversationSequence <= through && observed[id] == nil { rememberRemoval(id) }
        messages = messages.filter { _, message in
            message.conversationSequence <= after || message.conversationSequence > through || observed[message.id] != nil
        }
        for message in observed.values { merge(message) }
        guard !privacyBudgetExceeded else { throw NativeClientError.replayPrivacyBudgetExceeded }
        if historical && !observed.isEmpty { messages = messages.filter { $0.value.conversationSequence <= through } }
        cursor = max(cursor, through)
        let window = historical ? Array(sorted.prefix(500)) : Array(sorted.suffix(500))
        let retained = Set(window.map(\.id)); messages = messages.filter { retained.contains($0.key) }
    }
    /// Replace the whole authorized sidecar. A missing author must not keep an old name.
    mutating func replaceLabels(_ current: [SenderLabel]) throws {
        guard !privacyBudgetExceeded else { throw NativeClientError.replayPrivacyBudgetExceeded }
        for label in current where label.redacted && !redactedAuthors.contains(label.id) {
            guard redactedAuthors.count < 2000 else { exceedPrivacyBudget(); throw NativeClientError.replayPrivacyBudgetExceeded }
            redactedAuthors.insert(label.id)
        }
        let visible = Set(messages.values.map(\.senderUserId))
        labels = Dictionary(current.filter { visible.contains($0.id) }.map {
            ($0.id, redactedAuthors.contains($0.id) ? SenderLabel(id: $0.id, displayName: "Former member", redacted: true) : $0)
        }, uniquingKeysWith: { _, last in last })
    }
    private mutating func exceedPrivacyBudget() {
        privacyBudgetExceeded = true
        messages.removeAll(keepingCapacity: false); labels.removeAll(keepingCapacity: false)
    }
    private mutating func rememberRemoval(_ id: String) {
        guard !privacyBudgetExceeded else { return }
        if tombstones.count < 2000 { tombstones.insert(id) } else if !tombstones.contains(id) { exceedPrivacyBudget() }
    }
    mutating func merge(_ message: Message) {
        guard !privacyBudgetExceeded else { return }
        if message.status != "active" { rememberRemoval(message.id) }
        if privacyBudgetExceeded || (message.status == "active" && tombstones.contains(message.id)) { return }
        if let old = messages[message.id] {
            guard old.conversationId == message.conversationId, old.conversationSequence == message.conversationSequence else { return }
            if old.status != "active" && message.status == "active" { return }
            let previousRevision = Wire.date(old.deletedAt ?? old.editedAt ?? old.insertedAt) ?? .distantPast
            let incomingRevision = Wire.date(message.deletedAt ?? message.editedAt ?? message.insertedAt) ?? .distantPast
            if old.status == message.status && incomingRevision < previousRevision { return }
        }
        messages[message.id] = message
    }
}
