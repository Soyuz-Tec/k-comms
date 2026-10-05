package com.soyuz.kcomms.ui

import android.content.Context
import com.soyuz.kcomms.media.ForegroundMedia
import com.soyuz.kcomms.protocol.*
import com.soyuz.kcomms.security.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.json.*
import java.time.Instant
import java.util.UUID

enum class AppSection { CONVERSATIONS, DIRECTORY, CALLS, MEETINGS, PHONE }
data class RenderedMessage(val message: Message, val sender: String)
data class SignInChallenge(val endpoint: Endpoint, val epoch: Long, val challenge: MfaChallenge, val expiresAt: Long) {
    override fun toString() = "SignInChallenge(credentials redacted)"
}
data class AppState(
    val restoring: Boolean = true, val identity: SessionIdentity? = null, val capabilities: MemberCapabilities? = null,
    val busy: Boolean = false, val error: String? = null, val notice: String? = null,
    val challenge: SignInChallenge? = null, val section: AppSection = AppSection.CONVERSATIONS,
    val conversations: List<Conversation> = emptyList(), val directory: List<DirectoryPerson> = emptyList(),
    val directoryQuery: String = "", val directoryCursor: String? = null,
    val selected: Conversation? = null, val messages: List<RenderedMessage> = emptyList(),
    val pending: List<PendingMessage> = emptyList(), val hasOlder: Boolean = false,
    val hasNewer: Boolean = false, val calls: List<Call> = emptyList(), val callsCursor: String? = null,
    val meetings: List<Meeting> = emptyList(), val phoneConfiguration: PhoneConfiguration? = null,
    val phoneCapabilities: PhoneCapabilities? = null, val phoneCalls: List<PhoneCall> = emptyList(),
    val phoneCursor: String? = null, val phoneControl: PhoneControlReceipt? = null,
    val pendingDialDestination: String? = null,
) {
    val workspaceEligible get() = identity?.authentication?.user?.workspaceEligible == true
    val visibleSections get() = if (workspaceEligible) AppSection.entries else listOf(AppSection.CONVERSATIONS, AppSection.CALLS)

    fun withoutWorkspaceData() = copy(
        section = if (section in listOf(AppSection.DIRECTORY, AppSection.MEETINGS, AppSection.PHONE)) AppSection.CONVERSATIONS else section,
        directory = emptyList(), directoryQuery = "", directoryCursor = null, meetings = emptyList(),
        phoneConfiguration = null, phoneCapabilities = null, phoneCalls = emptyList(), phoneCursor = null,
        phoneControl = null, pendingDialDestination = null,
    )
    fun withOwnerIdentity(owner: SessionIdentity?): AppState {
        val next = copy(identity = owner)
        return if (next.workspaceEligible) next else next.withoutWorkspaceData()
    }
}

/** One process-local owner; credentials/outbox are the only encrypted persisted state. */
class AppController(context: Context, val api: KCommsApi) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    val media = ForegroundMedia(context.applicationContext, api.sessions, scope)
    private val mutableState = MutableStateFlow(AppState())
    val state = mutableState.asStateFlow()
    private val socket = PhoenixSocket(api)
    private val admissionFence = ForegroundAdmissionFence()
    private val active get() = admissionFence.foreground
    private var conversationSerial = 0L
    private var replay: MessageReplay? = null
    private var replayBusy = false
    private var replayAgain = false
    private var activeCall: Call? = null
    private var activePhone: PhoneCall? = null
    private var uncertainDial: Pair<String, String>? = null
    private var watchdog: Job? = null
    private var restoreJob: Job? = null

    init {
        scope.launch {
            var previous: IdentityLease? = null
            api.sessions.identity.collect { identity ->
                if (previous != identity?.lease) {
                    previous = identity?.lease
                    admissionFence.invalidatePending()
                    conversationSerial += 1; socket.stop(); replay = null
                    replayBusy = false; replayAgain = false; activeCall = null; activePhone = null; uncertainDial = null
                    media.stop()
                    if (api.sessions.identity.value?.lease != identity?.lease) return@collect
                    mutableState.value = AppState(restoring = false, identity = identity)
                    if (identity != null && active) refresh()
                } else applyOwnerIdentity(identity)
            }
        }
        media.onUserDisconnect = { endMedia() }
    }

    private fun update(block: AppState.() -> AppState) { mutableState.value = mutableState.value.block() }
    private fun publish(lease: IdentityLease, block: AppState.() -> AppState) {
        api.sessions.requireCurrent(lease); update(block)
    }
    private fun applyOwnerIdentity(identity: SessionIdentity?) {
        if (state.value.workspaceEligible && identity?.authentication?.user?.workspaceEligible != true) {
            // Conversation media stays under its current membership/capability admission.
            activePhone = null; uncertainDial = null
        }
        update { withOwnerIdentity(identity) }
    }
    private fun publishOwner(lease: IdentityLease, me: Me) {
        api.sessions.requireCurrent(lease)
        applyOwnerIdentity(api.sessions.identity.value)
        publish(lease) { copy(capabilities = me.capabilities) }
    }
    private fun safeError(failure: Throwable) = when (failure) {
        is ApiFailure -> when (failure.status) {
            401 -> "Sign in again to continue."
            403, 404 -> "This item is unavailable with your current access."
            409 -> "This item changed. Refresh it before trying again."
            422 -> "The server could not accept these details. Check them and try again."
            503 -> "The service is currently unavailable. Try again later."
            else -> "The request could not be completed. Refresh before retrying."
        }
        is IdentityChanged -> "Your account changed. Sign in again."
        is WorkspaceAccessUnavailable -> "Directory, new conversations, meetings and phone require current workspace access. Your admitted conversations remain available."
        else -> "The connection or response could not be verified. Retry deliberately."
    }
    private fun task(workspaceOnly: Boolean = false, block: suspend (IdentityLease) -> Unit) {
        if (state.value.busy || state.value.identity == null) return
        val lease = api.sessions.capture()
        scope.launch {
            publish(lease) { copy(busy = true, error = null, notice = null) }
            try { block(lease) }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (failure: Exception) {
                if (api.sessions.isCurrent(lease)) {
                    if (workspaceOnly && failure is ApiFailure && failure.status in listOf(403, 404)) {
                        update { withoutWorkspaceData() }; uncertainDial = null
                        try { publishOwner(lease, api.me(lease)) }
                        catch (ownerFailure: Exception) {
                            if (ownerFailure is IdentityChanged || ownerFailure is ApiFailure && ownerFailure.status in listOf(401, 403, 404))
                                api.sessions.invalidate()
                        }
                    } else if (failure is ApiFailure && failure.status in listOf(401, 403, 404)) {
                        conversationSerial += 1; replay = null; socket.stop(); media.stop()
                        publish(lease) { copy(conversations = emptyList(), directory = emptyList(), selected = null,
                            messages = emptyList(), pending = emptyList(), calls = emptyList(), meetings = emptyList(),
                            phoneCalls = emptyList(), phoneConfiguration = null, phoneControl = null, pendingDialDestination = null) }
                    }
                    if (api.sessions.isCurrent(lease)) publish(lease) { copy(error = safeError(failure)) }
                }
            } finally { if (api.sessions.isCurrent(lease)) publish(lease) { copy(busy = false) } }
        }
    }
    private fun workspaceTask(block: suspend (IdentityLease) -> Unit) = task(workspaceOnly = true) { lease ->
        publishOwner(lease, api.me(lease))
        api.sessions.requireWorkspace(lease)
        block(lease)
    }
    private suspend fun workspaceProjection(lease: IdentityLease, block: suspend () -> Unit) {
        try { block() }
        catch (failure: ApiFailure) {
            if (failure.status !in listOf(403, 404)) throw failure
            update { withoutWorkspaceData() }; uncertainDial = null
            publishOwner(lease, api.me(lease))
            throw WorkspaceAccessUnavailable()
        }
    }

    fun foreground(value: Boolean) {
        admissionFence.setForeground(value)
        if (!value) {
            watchdog?.cancel(); socket.stop()
            activeCall = null; activePhone = null
            scope.launch { media.stop() }
            return
        }
        if (restoreJob == null) restoreJob = scope.launch {
            api.sessions.restore(); update { copy(restoring = false) }
            if (active && api.sessions.identity.value != null) refresh()
        }
        if (api.sessions.identity.value != null) refresh()
        watchdog?.cancel()
        watchdog = scope.launch {
            while (active && isActive) {
                delay(1000)
                val challenge = state.value.challenge
                if (challenge != null && android.os.SystemClock.elapsedRealtime() >= challenge.expiresAt) {
                    update { copy(challenge = null, error = "Verification expired. Sign in again.") }
                }
                val lease = api.sessions.identity.value?.lease ?: continue
                if (api.sessions.remainingAccessMillis() <= 60_000) {
                    try { api.sessions.ensureFresh(lease) }
                    catch (_: Exception) {
                        if (api.sessions.remainingAccessMillis() == 0L) { media.stop(); api.sessions.expireIfNecessary() }
                        delay(4000)
                    }
                }
            }
        }
    }

    fun signIn(origin: String, tenant: String, email: String, password: String) {
        if (state.value.busy) return
        scope.launch {
            update { copy(busy = true, challenge = null, error = null) }
            try {
                media.stop(); socket.stop()
                val endpoint = Endpoint.parse(origin)
                val (epoch, result) = api.signIn(endpoint, tenant, email, password)
                if (result is SignInResult.Challenge) update {
                    copy(challenge = SignInChallenge(endpoint, epoch, result.challenge,
                        android.os.SystemClock.elapsedRealtime() + result.challenge.expiresIn * 1000))
                }
            } catch (failure: Exception) { update { copy(error = safeError(failure)) } }
            finally { update { copy(busy = false) } }
        }
    }
    fun completeMfa(code: String) {
        val challenge = state.value.challenge ?: return
        if (state.value.busy) return
        if (android.os.SystemClock.elapsedRealtime() >= challenge.expiresAt) {
            update { copy(challenge = null, error = "Verification expired. Sign in again.") }; return
        }
        scope.launch {
            update { copy(busy = true, error = null) }
            try { api.completeMfa(challenge.endpoint, challenge.epoch, challenge.challenge.token, code); update { copy(challenge = null) } }
            catch (failure: Exception) { update { copy(error = safeError(failure)) } }
            finally { update { copy(busy = false) } }
        }
    }
    fun cancelMfa() { scope.launch { api.sessions.resetForSignIn(); update { copy(challenge = null, busy = false) } } }
    fun logout() {
        admissionFence.invalidatePending(); socket.stop(); activeCall = null; activePhone = null
        scope.launch {
            val stopped = launch { media.stop() }
            api.sessions.logout(); stopped.join()
        }
    }
    fun section(section: AppSection) {
        if (section !in state.value.visibleSections) return
        update { copy(section = section) }; refresh()
    }

    fun refresh() = task { lease ->
        try { api.sessions.ensureFresh(lease); publishOwner(lease, api.me(lease)) }
        catch (failure: Exception) {
            if (failure is IdentityChanged || failure is ApiFailure && failure.status in listOf(401, 403, 404)) {
                media.stop(); api.sessions.invalidate()
            }
            throw failure
        }
        val conversations = api.conversations(lease)
        publish(lease) { copy(conversations = conversations.filter { it.archivedAt == null }.take(200)) }
        when (state.value.section) {
            AppSection.CONVERSATIONS -> if (state.value.selected != null) replayVisible(lease)
            AppSection.DIRECTORY -> workspaceProjection(lease) { loadDirectory(lease, state.value.directoryQuery, null) }
            AppSection.CALLS -> { val page = api.calls(lease = lease); publish(lease) { copy(calls = page.data.take(200), callsCursor = page.page.nextCursor) } }
            AppSection.MEETINGS -> workspaceProjection(lease) { val values = api.meetings(lease); publish(lease) { copy(meetings = values.take(200)) } }
            AppSection.PHONE -> workspaceProjection(lease) { refreshPhone(lease) }
        }
        if (active) connectSocket(lease)
    }

    fun searchDirectory(query: String) = workspaceTask { loadDirectory(it, query, null) }
    fun moreDirectory() = workspaceTask { loadDirectory(it, state.value.directoryQuery, state.value.directoryCursor) }
    private suspend fun loadDirectory(lease: IdentityLease, query: String, cursor: String?) {
        val page = api.directory(query, cursor, lease)
        publish(lease) { copy(directoryQuery = query, directoryCursor = page.page.nextCursor,
            directory = (if (cursor == null) page.data else directory + page.data).distinctBy { it.id }.take(200)) }
    }
    fun direct(person: DirectoryPerson) = workspaceTask { lease -> open(api.direct(person.id, lease), lease) }
    fun group(title: String, memberIds: List<String>) = workspaceTask { lease ->
        require(title.isNotBlank() && memberIds.isNotEmpty() && memberIds.size <= 50)
        open(api.group(title, memberIds, lease), lease)
    }
    fun select(conversation: Conversation) = task { open(conversation, it) }
    fun closeConversation() {
        conversationSerial += 1; replay = null
        update { copy(selected = null, messages = emptyList(), pending = emptyList(), hasOlder = false, hasNewer = false) }
        api.sessions.identity.value?.lease?.let(::connectSocket)
    }
    private suspend fun open(conversation: Conversation, lease: IdentityLease) {
        require(conversation.tenantId == lease.tenantId)
        conversationSerial += 1; val serial = conversationSerial
        socket.stop(); replay = MessageReplay(lease.tenantId, conversation.id)
        publish(lease) { copy(section = AppSection.CONVERSATIONS, selected = conversation, messages = emptyList(), pending = emptyList()) }
        val page = api.latestHistory(conversation, lease = lease)
        if (serial != conversationSerial) return
        replay?.apply(page); replay?.trim(); refreshLabels(lease, conversation.id); renderMessages(lease)
        publish(lease) { copy(hasOlder = (replay?.oldest ?: 1) > 1, hasNewer = page.page.hasMore) }
        if (active) connectSocket(lease)
    }
    private suspend fun refreshLabels(lease: IdentityLease, conversationId: String) {
        val current = replay ?: return
        val labels = current.values.map { it.id }.chunked(200).flatMap { api.senderLabels(conversationId, it, lease) }
        if (state.value.selected?.id == conversationId) current.replaceLabels(labels)
    }
    private suspend fun renderMessages(lease: IdentityLease) {
        val current = replay ?: return
        val pending = api.sessions.pending(lease).filter { it.conversationId == state.value.selected?.id }
        publish(lease) { copy(messages = current.values.map { RenderedMessage(it, current.label(it)) }, pending = pending) }
    }
    fun olderMessages() = task { lease ->
        val selected = state.value.selected ?: return@task
        val current = replay ?: return@task; val oldest = current.oldest ?: return@task
        val page = api.history(selected.id, after = (oldest - 101).coerceAtLeast(0), before = oldest, lease = lease)
        current.apply(page, historical = true); current.trim(historical = true); refreshLabels(lease, selected.id); renderMessages(lease)
        publish(lease) { copy(hasOlder = (current.oldest ?: 1) > 1, hasNewer = true) }
    }
    fun newerMessages() = task { lease ->
        val selected = state.value.selected ?: return@task; val current = replay ?: return@task
        val page = api.history(selected.id, after = current.values.lastOrNull()?.sequence ?: 0, lease = lease)
        current.apply(page); current.trim(); refreshLabels(lease, selected.id); renderMessages(lease)
        publish(lease) { copy(hasOlder = (current.oldest ?: 1) > 1, hasNewer = page.page.hasMore) }
    }
    private suspend fun replayVisible(lease: IdentityLease) {
        if (replayBusy) { replayAgain = true; return }
        val selected = state.value.selected ?: return
        val current = replay ?: return; val serial = conversationSerial
        val first = current.oldest ?: return; val last = current.values.lastOrNull()?.sequence ?: return
        replayBusy = true
        try {
            val pages = mutableListOf<MessagePage>(); var after = first - 1; var finished = false
            repeat(5) {
                if (finished) return@repeat
                val page = api.history(selected.id, after = after, before = last + 1, limit = 200, lease = lease)
                if (serial != conversationSerial) return
                pages += page
                if (!page.page.hasMore) finished = true
                else {
                    val next = page.page.nextAfterSequence ?: throw ProtocolFailure()
                    if (next <= after || next > last) throw ProtocolFailure()
                    after = next
                }
            }
            if (!finished) throw ProtocolFailure()
            current.replaceVisibleRange(first, last, pages)
            refreshLabels(lease, selected.id); renderMessages(lease)
        } catch (failure: Exception) {
            if (api.sessions.isCurrent(lease) && serial == conversationSerial) {
                // A denied projection cannot leave earlier private body/label data visible.
                if (failure is ApiFailure && failure.status in listOf(401, 403, 404)) {
                    replay = null; publish(lease) { copy(messages = emptyList(), pending = emptyList(), selected = null) }
                }
                publish(lease) { copy(error = safeError(failure)) }
            }
        } finally {
            replayBusy = false
            if (replayAgain && active && serial == conversationSerial) { replayAgain = false; scope.launch { replayVisible(lease) } }
        }
    }
    private fun connectSocket(lease: IdentityLease) {
        if (!active) return
        socket.start(scope, lease, state.value.selected?.id, replay?.highWater ?: 0,
            onEvent = { event ->
                if (api.sessions.isCurrent(lease)) {
                    scope.launch {
                        try {
                            val current = replay
                            if (current?.apply(event) == true) { renderMessages(lease); replayVisible(lease); catchUp(lease) }
                        } catch (_: Exception) { if (api.sessions.isCurrent(lease)) update { copy(error = "Current conversation activity could not be verified. Refresh to continue.") } }
                    }
                    if (event.event.startsWith("call.") || event.event.startsWith("telephony.")) refresh()
                }
            }, onReconnected = { scope.launch { replayVisible(lease); catchUp(lease) } })
    }
    private suspend fun catchUp(lease: IdentityLease) {
        val selected = state.value.selected ?: return; val current = replay ?: return
        val serial = conversationSerial
        try {
            repeat(3) {
                val after = current.values.lastOrNull()?.sequence ?: 0
                val page = api.history(selected.id, after = after, limit = 200, lease = lease)
                if (serial != conversationSerial) return
                if (page.data.isNotEmpty() && (page.page.nextAfterSequence ?: 0) <= after) throw ProtocolFailure()
                current.apply(page); refreshLabels(lease, selected.id); renderMessages(lease)
                publish(lease) { copy(hasOlder = (current.oldest ?: 1) > 1, hasNewer = page.page.hasMore) }
                if (!page.page.hasMore) return
            }
            publish(lease) { copy(notice = "Newer retained messages remain. Load newer messages to continue through the bounded history window.") }
        } catch (failure: Exception) {
            if (api.sessions.isCurrent(lease) && serial == conversationSerial) {
                if (failure is ApiFailure && failure.status in listOf(401, 403, 404)) {
                    replay = null; publish(lease) { copy(messages = emptyList(), pending = emptyList(), selected = null) }
                }
                publish(lease) { copy(error = safeError(failure)) }
            }
        }
    }
    fun send(body: String) = task { lease ->
        val selected = state.value.selected ?: return@task
        val command = api.sessions.enqueue(selected.id, body, lease)
        renderMessages(lease)
        val message = api.send(command, lease); replay?.apply(message); renderMessages(lease)
    }
    fun retry(command: PendingMessage) = task { lease -> replay?.apply(api.send(command, lease)); renderMessages(lease) }
    fun discard(command: PendingMessage) = task { lease -> api.sessions.discard(command, lease); renderMessages(lease) }
    fun edit(message: Message, body: String) = task { lease ->
        require(message.senderId == lease.userId && message.conversationId == state.value.selected?.id)
        replay?.apply(api.edit(message.id, body, lease)); renderMessages(lease)
    }
    fun delete(message: Message) = task { lease ->
        require(message.senderId == lease.userId && message.conversationId == state.value.selected?.id)
        replay?.apply(api.delete(message.id, lease)); renderMessages(lease)
    }

    private fun mediaTask(workspaceOnly: Boolean = false, block: suspend (IdentityLease) -> Unit) {
        val serial = admissionFence.capture()
        task(workspaceOnly = workspaceOnly) { lease -> requireForeground(serial); api.sessions.ensureFresh(lease); requireForeground(serial); block(lease) }
    }
    private fun workspaceMediaTask(block: suspend (IdentityLease, Long) -> Unit) = mediaTask(workspaceOnly = true) { lease ->
        publishOwner(lease, api.me(lease))
        val generation = api.sessions.captureWorkspace(lease)
        block(lease, generation)
    }
    private fun requireForeground(serial: Long) = admissionFence.requireCurrent(serial)
    fun startCall(video: Boolean) {
        val serial = admissionFence.capture()
        mediaTask { lease ->
            val selected = state.value.selected ?: return@mediaTask
            val admission = api.startCall(selected.id, video, lease); requireForeground(serial)
            activeCall = admission.data; activePhone = null; media.connect(admission, lease)
        }
    }
    fun joinCall(call: Call) {
        val serial = admissionFence.capture()
        mediaTask { lease -> val admission = api.joinCall(call, lease); requireForeground(serial)
            activeCall = admission.data; activePhone = null; media.connect(admission, lease) }
    }
    fun endMedia() {
        admissionFence.invalidatePending()
        val call = activeCall; val phone = activePhone
        val lease = api.sessions.identity.value?.lease
        activeCall = null; activePhone = null
        scope.launch {
            media.stop()
            if (lease == null) return@launch
            try {
                api.sessions.requireCurrent(lease)
                if (phone != null && phone.canEnd) api.endPhone(phone.id, lease)
                else if (call != null && call.canEnd) api.endCall(call, lease)
                publish(lease) { copy(notice = "Local media stopped. Refresh history to check the server call status.") }
            } catch (failure: Exception) {
                if (api.sessions.isCurrent(lease)) publish(lease) { copy(error = safeError(failure),
                    notice = "Local media stopped. The server end result was not verified; refresh history.") }
            }
        }
    }
    fun moreCalls() = task { lease -> val page = api.calls(state.value.callsCursor, lease)
        publish(lease) { copy(calls = (calls + page.data).distinctBy { it.id }.takeLast(200), callsCursor = page.page.nextCursor) } }
    fun schedule(title: String, localStart: String, timezone: String, duration: Int) = workspaceTask { lease ->
        val selected = state.value.selected ?: return@workspaceTask
        val meeting = api.schedule(selected.id, title, localStart, timezone, duration, lease)
        publish(lease) { copy(meetings = (meetings + meeting).distinctBy { it.id }, notice = "Meeting scheduled.") }
    }
    fun cancelMeeting(meeting: Meeting) = workspaceTask { lease -> api.cancelMeeting(meeting, lease)
        val meetings = api.meetings(lease); publish(lease) { copy(meetings = meetings) } }
    fun startMeeting(meeting: Meeting, occurrence: MeetingOccurrence, video: Boolean) {
        val serial = admissionFence.capture()
        workspaceMediaTask { lease, generation -> val admission = api.startMeeting(meeting, occurrence, video, lease); requireForeground(serial)
            api.sessions.requireWorkspace(lease, generation)
            activeCall = admission.data; activePhone = null; media.connect(admission, lease) }
    }
    private suspend fun refreshPhone(lease: IdentityLease) {
        val generation = api.sessions.captureWorkspace(lease)
        val configuration = api.phoneConfiguration(lease)
        val capabilities = api.phoneCapabilities(lease)
        val calls = api.phoneCalls(lease = lease)
        api.sessions.requireWorkspace(lease, generation)
        publish(lease) { copy(phoneConfiguration = configuration, phoneCapabilities = capabilities,
            phoneCalls = calls.data.take(200), phoneCursor = calls.page.nextCursor) }
    }
    fun dialPhone(destination: String) {
        val serial = admissionFence.capture()
        workspaceMediaTask { lease, generation ->
            val pending = uncertainDial
            require(pending == null || pending.first == destination) { "Reconcile the pending dial first." }
            val command = pending ?: (destination to UUID.randomUUID().toString()).also { uncertainDial = it }
            publish(lease) { copy(pendingDialDestination = command.first) }
            val admission = api.dialPhone(command.first, command.second, lease); requireForeground(serial)
            api.sessions.requireWorkspace(lease, generation)
            uncertainDial = null; publish(lease) { copy(pendingDialDestination = null) }
            activePhone = admission.data; activeCall = null; media.connectPhone(admission, lease)
        }
    }
    fun answerPhone(call: PhoneCall, join: Boolean = false) {
        val serial = admissionFence.capture()
        workspaceMediaTask { lease, generation -> val admission = if (join) api.joinPhone(call.id, lease) else api.answerPhone(call.id, lease)
            requireForeground(serial); api.sessions.requireWorkspace(lease, generation)
            activePhone = admission.data; activeCall = null; media.connectPhone(admission, lease) }
    }
    fun rejectPhone(call: PhoneCall) = workspaceTask { lease -> api.rejectPhone(call.id, lease); refreshPhone(lease) }
    fun endPhone(call: PhoneCall) = workspaceTask { lease ->
        require(call.canEnd)
        if (activePhone?.id == call.id) {
            admissionFence.invalidatePending(); activePhone = null
            media.stop()
        }
        api.endPhone(call.id, lease); refreshPhone(lease)
    }
    fun morePhoneCalls() = workspaceTask { lease -> val page = api.phoneCalls(state.value.phoneCursor, lease)
        publish(lease) { copy(phoneCalls = (phoneCalls + page.data).distinctBy { it.id }.takeLast(200), phoneCursor = page.page.nextCursor) } }
    fun dtmf(digit: Char) {
        val serial = admissionFence.capture()
        workspaceMediaTask { lease, generation ->
        val phone = activePhone ?: return@workspaceMediaTask
        require(media.state.value.phoneCallId == phone.id && digit in "0123456789*#")
        val receipt = api.phoneControl(phone.id, digit.toString(), UUID.randomUUID().toString(), lease)
        require(receipt.callId == phone.id && receipt.action == "dtmf")
        publish(lease) { copy(phoneControl = receipt) }
        if (!receipt.dispatch || Instant.parse(receipt.expiresAt) <= Instant.now()) return@workspaceMediaTask
        var completion = "unknown"
        try { requireForeground(serial); api.sessions.requireWorkspace(lease, generation); media.dtmf(digit, phone.id, lease); completion = "submitted" }
        finally {
            // A completion or SDK uncertainty is reconciled explicitly; never redispatch a digit.
            if (api.sessions.isCurrent(lease)) {
                val current = api.completePhoneControl(phone.id, receipt.id, completion, lease)
                publish(lease) { copy(phoneControl = current, notice = "DTMF command ${current.status}. Submitted does not prove carrier delivery.") }
            }
        }
        }
    }
    fun reconcilePhoneControl() = workspaceTask { lease ->
        val receipt = state.value.phoneControl ?: return@workspaceTask
        val result = api.reconcilePhoneControl(receipt.callId, receipt.id, lease)
        publish(lease) { copy(phoneControl = result, notice = "Command ${result.status}; no digit was resent.") }
    }
    fun microphone(enabled: Boolean) = mediaTask { media.setMicrophoneEnabled(enabled) }
    fun camera(enabled: Boolean) = mediaTask { media.setCameraEnabled(enabled) }
    fun endpoint(id: String) = mediaTask { media.selectEndpoint(id) }
}
