import AVFoundation
import CallKit
import Foundation

enum NativeSystemCall {
    case conversation(Call), phone(PhoneCall)
    var id: String { switch self { case .conversation(let call): return call.id; case .phone(let call): return call.id } }
    var isVideo: Bool { if case .conversation(let call) = self { return call.isVideo }; return false }
    var isActive: Bool { switch self { case .conversation(let call): return call.status == "active"; case .phone(let call): return call.isActive } }
    var isIncoming: Bool { if case .phone(let call) = self { return call.direction == "inbound" }; return false }
}
@MainActor final class CallKitBridge: NSObject, CXProviderDelegate {
    private let provider: CXProvider
    private let controller = CXCallController()
    private var admittedCall: NativeSystemCall?
    private var admittedUUID: UUID?
    private var generation: UInt64 = 0
    private var actionGenerations: [UUID: UInt64] = [:]
    var onJoin: (@MainActor (NativeSystemCall) async throws -> Void)?
    var onLeave: (@MainActor () async -> Void)?
    var onMute: (@MainActor (Bool) async throws -> Void)?
    var onAudioActivated: (@MainActor (Bool) -> Void)?
    override init() {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = true; configuration.maximumCallGroups = 1; configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.generic]; configuration.includesCallsInRecents = false
        provider = CXProvider(configuration: configuration)
        super.init(); provider.setDelegate(self, queue: .main)
    }
    /// The value came from an authorized owned-call API; an OS action is still re-admitted.
    func begin(_ call: Call) async throws {
        try await begin(.conversation(call))
    }
    func beginPhone(_ call: PhoneCall) async throws { try await begin(.phone(call)) }
    private func begin(_ call: NativeSystemCall) async throws {
        guard admittedCall == nil, UUID(uuidString: call.id) != nil, call.isActive else { throw NativeClientError.invalidResponse }
        generation &+= 1; let expected = generation
        // A rejoin of the same backend call is a fresh OS call. Old OS actions cannot
        // match it merely because the business call ID stayed the same.
        let uuid = UUID(); admittedCall = call; admittedUUID = uuid
        if call.isIncoming {
            let update = CXCallUpdate(); update.remoteHandle = CXHandle(type: .generic, value: "K-Comms phone call"); update.hasVideo = false
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    provider.reportNewIncomingCall(with: uuid, update: update) { error in if let error { continuation.resume(throwing: error) } else { continuation.resume() } }
                }
                guard expected == generation, admittedCall?.id == call.id else { throw NativeClientError.sessionChanged }
                try await controller.request(CXTransaction(action: CXAnswerCallAction(call: uuid)))
                guard expected == generation, admittedCall?.id == call.id else { throw NativeClientError.sessionChanged }
            } catch { if expected == generation { terminate(reason: .failed) }; throw error }
            return
        }
        let action = CXStartCallAction(call: uuid, handle: CXHandle(type: .generic, value: "K-Comms call")); action.isVideo = call.isVideo
        do { try await controller.request(CXTransaction(action: action)); guard expected == generation, admittedUUID == uuid else { throw NativeClientError.sessionChanged } }
        catch { if expected == generation { terminate(reason: .failed) }; throw error }
    }
    func leave() async {
        guard let call = admittedCall, let uuid = admittedUUID else { await onLeave?(); return }
        let expected = generation
        do { try await controller.request(CXTransaction(action: CXEndCallAction(call: uuid))) }
        catch { guard expected == generation, admittedCall?.id == call.id else { return }; terminate(reason: .failed); await onLeave?() }
    }
    func terminate(reason: CXCallEndedReason = .remoteEnded) {
        generation &+= 1
        actionGenerations.removeAll()
        if let uuid = admittedUUID { provider.reportCall(with: uuid, endedAt: Date(), reason: reason) }
        admittedCall = nil; admittedUUID = nil; onAudioActivated?(false)
    }
    func providerDidReset(_ provider: CXProvider) {
        generation &+= 1; let expected = generation
        actionGenerations.removeAll()
        admittedCall = nil; admittedUUID = nil; onAudioActivated?(false); Task { guard generation == expected else { return }; await onLeave?() }
    }
    func provider(_ provider: CXProvider, perform action: CXStartCallAction) { performJoin(action, uuid: action.callUUID) }
    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) { performJoin(action, uuid: action.callUUID) }
    private func performJoin(_ action: CXAction, uuid: UUID) {
        guard let call = admittedCall, admittedUUID == uuid, let onJoin else { action.fail(); return }
        let expected = generation
        actionGenerations[action.uuid] = expected
        Task {
            defer { if actionGenerations[action.uuid] == expected { actionGenerations.removeValue(forKey: action.uuid) } }
            do {
                guard expected == generation, admittedCall?.id == call.id else { action.fail(); return }
                try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .allowBluetoothA2DP])
                if !call.isIncoming { provider.reportOutgoingCall(with: uuid, startedConnectingAt: Date()) }
                try await onJoin(call)
                guard expected == generation, admittedCall?.id == call.id else { action.fail(); return }
                action.fulfill(); if !call.isIncoming { provider.reportOutgoingCall(with: uuid, connectedAt: Date()) }
            } catch {
                action.fail(); guard expected == generation, admittedCall?.id == call.id else { return }; terminate(reason: .failed); await onLeave?()
            }
        }
    }
    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        guard admittedCall != nil, admittedUUID == action.callUUID else { action.fail(); return }
        generation &+= 1; let expected = generation; admittedCall = nil; admittedUUID = nil; actionGenerations.removeAll(); onAudioActivated?(false)
        Task { guard expected == generation else { action.fail(); return }; await onLeave?(); action.fulfill() }
    }
    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        guard admittedCall != nil, admittedUUID == action.callUUID, let onMute else { action.fail(); return }
        let expected = generation
        actionGenerations[action.uuid] = expected
        Task {
            defer { if actionGenerations[action.uuid] == expected { actionGenerations.removeValue(forKey: action.uuid) } }
            do { guard expected == generation else { action.fail(); return }; try await onMute(action.isMuted); guard expected == generation else { action.fail(); return }; action.fulfill() } catch { action.fail() }
        }
    }
    func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        action.fail()
        guard actionGenerations[action.uuid] == generation, let callAction = action as? CXCallAction,
              admittedCall != nil, admittedUUID == callAction.callUUID else { return }
        terminate(reason: .failed); let expected = generation; Task { guard generation == expected else { return }; await onLeave?() }
    }
    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) { onAudioActivated?(true) }
    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) { onAudioActivated?(false) }
}

/// Neither Web Push registration nor a client wake hint grants native call admission.
enum NativePushAvailability {
    static let backgroundRingingEnabled = false
    static let explanation = "Background call notifications are not configured. Keep K-Comms open to see available calls."
    static func acceptUnqualifiedWake() throws { throw NativeClientError.featureUnavailable }
}
