package com.soyuz.kcomms.ui

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.soyuz.kcomms.media.MediaPhase
import com.soyuz.kcomms.media.MediaVideo
import com.soyuz.kcomms.security.IdentityLease
import com.soyuz.kcomms.protocol.*

@OptIn(ExperimentalLayoutApi::class)
@Composable fun KCommsApp(controller: AppController) {
    val state by controller.state.collectAsStateWithLifecycle()
    val media by controller.media.state.collectAsStateWithLifecycle()
    val context = LocalContext.current
    var pendingMedia by remember { mutableStateOf<(() -> Unit)?>(null) }
    var permissionIdentity by remember { mutableStateOf<IdentityLease?>(null) }
    var permissionError by remember { mutableStateOf<String?>(null) }
    val permissionLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { permissions ->
        val action = pendingMedia; pendingMedia = null
        if (permissionIdentity == controller.state.value.identity?.lease && permissions.filterKeys { it == Manifest.permission.RECORD_AUDIO || it == Manifest.permission.CAMERA }.values.all { it }) action?.invoke()
        else permissionError = "Microphone and requested camera permission are required to join this call."
    }
    fun withMediaPermission(video: Boolean, action: () -> Unit) {
        permissionError = null
        val required = buildList {
            add(Manifest.permission.RECORD_AUDIO)
            if (video) add(Manifest.permission.CAMERA)
            if (Build.VERSION.SDK_INT >= 33) add(Manifest.permission.POST_NOTIFICATIONS)
            if (Build.VERSION.SDK_INT >= 31) add(Manifest.permission.BLUETOOTH_CONNECT)
        }.filter { ContextCompat.checkSelfPermission(context, it) != PackageManager.PERMISSION_GRANTED }
        if (required.isEmpty()) action() else { permissionIdentity = state.identity?.lease; pendingMedia = action; permissionLauncher.launch(required.toTypedArray()) }
    }
    LaunchedEffect(state.identity?.lease) { pendingMedia = null; permissionIdentity = null; permissionError = null }
    MaterialTheme(colorScheme = if (isSystemInDarkTheme()) darkColorScheme() else lightColorScheme()) {
        Surface(modifier = Modifier.fillMaxSize()) {
            if (state.restoring) Column(Modifier.padding(24.dp)) { Text("Restoring this device's session…"); LinearProgressIndicator() }
            else if (state.identity == null) SignIn(state, controller)
            else Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding().imePadding()) {
                FlowRow(Modifier.fillMaxWidth().padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("K-Comms · ${state.identity!!.authentication.tenant.name}", style = MaterialTheme.typography.titleLarge, modifier = Modifier.padding(vertical = 12.dp))
                    TextButton(onClick = controller::refresh, enabled = !state.busy) { Text("Refresh") }
                    TextButton(onClick = controller::logout) { Text("Sign out") }
                }
                Text("Foreground only. Calls stop when this app leaves the screen. Native push is unavailable.",
                    style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp))
                FlowRow(Modifier.padding(horizontal = 12.dp), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    state.visibleSections.forEach { section ->
                        FilterChip(selected = state.section == section, onClick = { controller.section(section) },
                            label = { Text(section.name.lowercase().replaceFirstChar { it.uppercase() }) })
                    }
                }
                if (state.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
                state.error?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(16.dp)) }
                state.notice?.let { Text(it, modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp)) }
                permissionError?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(16.dp)) }
                if (media.phase != MediaPhase.IDLE) {
                    MediaControls(controller, onCamera = { withMediaPermission(true) { controller.camera(!media.cameraEnabled) } })
                }
                when (state.section.takeIf { it in state.visibleSections } ?: AppSection.CONVERSATIONS) {
                    AppSection.CONVERSATIONS -> Conversations(state, controller,
                        onCall = { video -> withMediaPermission(video) { controller.startCall(video) } })
                    AppSection.DIRECTORY -> Directory(state, controller)
                    AppSection.CALLS -> Calls(state, controller) { call -> withMediaPermission(call.mediaKind == "video") { controller.joinCall(call) } }
                    AppSection.MEETINGS -> Meetings(state, controller) { meeting, occurrence ->
                        withMediaPermission(false) { controller.startMeeting(meeting, occurrence, false) }
                    }
                    AppSection.PHONE -> Phone(state, controller,
                        dial = { number -> withMediaPermission(false) { controller.dialPhone(number) } },
                        answer = { call, join -> withMediaPermission(false) { controller.answerPhone(call, join) } })
                }
            }
        }
    }
}

@Composable private fun SignIn(state: AppState, controller: AppController) {
    var origin by remember { mutableStateOf("") }; var tenant by remember { mutableStateOf("") }
    var email by remember { mutableStateOf("") }; var password by remember { mutableStateOf("") }
    var code by remember(state.challenge) { mutableStateOf("") }
    Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding().imePadding().verticalScroll(rememberScrollState()).padding(24.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("K-Comms", style = MaterialTheme.typography.headlineLarge)
        Text("Sign in to your workspace. Passwords and verification codes stay in memory; device credentials are encrypted with Android Keystore.")
        Text("Corporate OIDC sign-in and administrator step-up proof are unavailable in this app. Use password sign-in with the server's authenticator or recovery-code challenge.", style = MaterialTheme.typography.bodySmall)
        if (state.challenge == null) {
            Field("Workspace HTTPS origin", origin, { origin = it }, placeholder = "https://workspace.example")
            Field("Workspace slug", tenant, { tenant = it })
            Field("Email", email, { email = it })
            OutlinedTextField(password, { password = it }, label = { Text("Password") }, visualTransformation = PasswordVisualTransformation(), singleLine = true, modifier = Modifier.fillMaxWidth())
            Button(onClick = { val secret = password; password = ""; controller.signIn(origin, tenant, email, secret) }, enabled = !state.busy && password.isNotEmpty() && origin.isNotBlank() && tenant.isNotBlank() && email.isNotBlank()) { Text("Sign in") }
        } else {
            Text("Enter your authenticator code or one-time recovery code.")
            OutlinedTextField(code, { code = it }, label = { Text("Verification code") }, visualTransformation = PasswordVisualTransformation(), singleLine = true, modifier = Modifier.fillMaxWidth())
            Button(onClick = { val secret = code; code = ""; controller.completeMfa(secret) }, enabled = !state.busy && code.isNotBlank()) { Text("Verify") }
            TextButton(onClick = controller::cancelMfa, enabled = !state.busy) { Text("Cancel verification") }
        }
        if (state.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
        state.error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        Text("Native push and incoming-call background wake are unavailable. Keep this app open to receive current activity.", style = MaterialTheme.typography.bodySmall)
    }
}

@Composable private fun Field(label: String, value: String, change: (String) -> Unit, placeholder: String = "") {
    OutlinedTextField(value, change, label = { Text(label) }, placeholder = { Text(placeholder) }, singleLine = true, modifier = Modifier.fillMaxWidth())
}

@OptIn(ExperimentalLayoutApi::class)
@Composable private fun Conversations(state: AppState, controller: AppController, onCall: (Boolean) -> Unit) {
    val selected = state.selected
    var draft by remember(state.identity?.lease, selected?.id) { mutableStateOf("") }
    var editing by remember(state.identity?.lease, selected?.id) { mutableStateOf<Message?>(null) }
    var editText by remember(editing?.id) { mutableStateOf(editing?.body ?: "") }
    var deletion by remember(state.identity?.lease, selected?.id) { mutableStateOf<Message?>(null) }
    var scheduling by remember(selected?.id, state.workspaceEligible) { mutableStateOf(false) }
    if (deletion != null) AlertDialog(onDismissRequest = { deletion = null }, title = { Text("Delete this message?") },
        text = { Text("The server checks current authority. This removes the message body from the conversation.") },
        confirmButton = { TextButton(onClick = { deletion?.let(controller::delete); deletion = null }) { Text("Delete") } },
        dismissButton = { TextButton(onClick = { deletion = null }) { Text("Cancel") } })
    if (editing != null) AlertDialog(onDismissRequest = { editing = null }, title = { Text("Edit message") },
        text = { OutlinedTextField(editText, { editText = it }, label = { Text("Message") }) },
        confirmButton = { TextButton(onClick = { editing?.let { controller.edit(it, editText) }; editing = null }, enabled = editText.isNotBlank()) { Text("Save") } },
        dismissButton = { TextButton(onClick = { editing = null }) { Text("Cancel") } })
    LazyColumn(Modifier.fillMaxSize().padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (selected == null) {
            item { Text("Conversations", style = MaterialTheme.typography.titleLarge) }
            if (state.conversations.isEmpty()) item {
                Text(if (state.workspaceEligible) "No admitted conversations. Find someone in Directory." else "No currently admitted conversations. Refresh to check current membership.")
            }
            items(state.conversations, key = { it.id }) { conversation ->
                OutlinedButton(onClick = { controller.select(conversation) }, enabled = !state.busy, modifier = Modifier.fillMaxWidth()) {
                    Text("${conversation.label} · ${conversation.unreadCount} unread")
                }
            }
        } else {
            item {
                TextButton(onClick = controller::closeConversation) { Text("Back to conversations") }
                Text(selected.label, style = MaterialTheme.typography.titleLarge)
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button(onClick = { onCall(false) }, enabled = !state.busy && state.capabilities?.allowAudioCalls == true) { Text("Audio call") }
                    Button(onClick = { onCall(true) }, enabled = !state.busy && state.capabilities?.allowVideoCalls == true) { Text("Video call") }
                    if (state.workspaceEligible) TextButton(onClick = { scheduling = !scheduling }) { Text("Schedule meeting") }
                }
                if (scheduling && state.workspaceEligible) ScheduleForm(state, controller)
                Text("Up to 500 messages are kept in memory. Refresh rechecks loaded edits, deletions and sender names.", style = MaterialTheme.typography.bodySmall)
                if (state.hasOlder) TextButton(onClick = controller::olderMessages, enabled = !state.busy) { Text("Load older messages") }
            }
            items(state.messages, key = { it.message.id }) { rendered ->
                val message = rendered.message
                Card(Modifier.fillMaxWidth()) {
                    Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text("${rendered.sender} · ${message.insertedAt}", style = MaterialTheme.typography.labelMedium)
                        Text(if (message.deleted) "Message deleted" else message.body ?: "Attachment message")
                        if (!message.deleted && message.senderId == state.identity?.lease?.userId) FlowRow {
                            TextButton(onClick = { editing = message }, enabled = !state.busy) { Text("Edit") }
                            TextButton(onClick = { deletion = message }, enabled = !state.busy) { Text("Delete") }
                        }
                    }
                }
            }
            item { TextButton(onClick = controller::newerMessages, enabled = !state.busy) { Text(if (state.hasNewer) "Load newer messages" else "Check for newer messages") } }
            items(state.pending, key = { it.commandId }) { pending ->
                Card { Column(Modifier.padding(12.dp)) {
                    Text("Pending: ${pending.body}")
                    Text("An uncertain response is retried only with this same message command.", style = MaterialTheme.typography.bodySmall)
                    FlowRow {
                        TextButton(onClick = { controller.retry(pending) }, enabled = !state.busy) { Text("Retry same message") }
                        TextButton(onClick = { controller.discard(pending) }, enabled = !state.busy) { Text("Discard pending") }
                    }
                } }
            }
            item {
                OutlinedTextField(draft, { draft = it }, label = { Text("Message") }, modifier = Modifier.fillMaxWidth())
                Button(onClick = { val body = draft; draft = ""; controller.send(body) }, enabled = !state.busy && draft.isNotBlank() && draft.toByteArray().size <= 16000) { Text("Send") }
            }
        }
    }
}

@Composable private fun ScheduleForm(state: AppState, controller: AppController) {
    var title by remember { mutableStateOf("") }; var start by remember { mutableStateOf("") }
    var zone by remember { mutableStateOf(java.time.ZoneId.systemDefault().id) }; var duration by remember { mutableStateOf("30") }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Field("Meeting title", title, { title = it }); Field("Local start", start, { start = it }, "2026-10-05T14:30:00")
        Field("Time zone", zone, { zone = it }, "Europe/London"); Field("Duration in minutes", duration, { duration = it })
        Button(onClick = { controller.schedule(title, start, zone, duration.toInt()) }, enabled = !state.busy && title.isNotBlank() && start.isNotBlank() && (duration.toIntOrNull() ?: 0) in 5..480) { Text("Create meeting") }
    }
}

@Composable private fun Directory(state: AppState, controller: AppController) {
    var query by remember { mutableStateOf(state.directoryQuery) }; var title by remember { mutableStateOf("") }
    var selected by remember(state.identity?.lease) { mutableStateOf(setOf<String>()) }
    LazyColumn(Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        item {
            Text("People", style = MaterialTheme.typography.titleLarge)
            Field("Find people", query, { query = it }); Button(onClick = { controller.searchDirectory(query) }, enabled = !state.busy) { Text("Search") }
            Field("Private group name", title, { title = it.take(80) })
            Button(onClick = { controller.group(title, selected.toList()) }, enabled = !state.busy && title.isNotBlank() && selected.size in 1..50) { Text("Create group with ${selected.size} selected") }
        }
        items(state.directory, key = { it.id }) { person ->
            Card(Modifier.fillMaxWidth()) { Column(Modifier.padding(12.dp)) {
                val duplicate = state.directory.count { it.displayName == person.displayName } > 1
                Text(person.displayName + if (duplicate) " · ${person.id.take(8)}" else "")
                TextButton(onClick = { controller.direct(person) }, enabled = !state.busy) { Text("Message ${person.displayName}") }
                Row {
                    Checkbox(checked = person.id in selected, onCheckedChange = { checked -> selected = if (checked) selected + person.id else selected - person.id }, enabled = selected.size < 50 || person.id in selected)
                    Text("Include in private group", modifier = Modifier.padding(top = 14.dp))
                }
            } }
        }
        if (state.directoryCursor != null && state.directory.size < 200) item { TextButton(onClick = controller::moreDirectory, enabled = !state.busy) { Text("Load more people") } }
    }
}

@Composable private fun Calls(state: AppState, controller: AppController, join: (Call) -> Unit) {
    LazyColumn(Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        item { Text("Recent call history", style = MaterialTheme.typography.titleLarge) }
        if (state.calls.isEmpty()) item { Text("No retained calls are available.") }
        items(state.calls, key = { it.id }) { call -> Card(Modifier.fillMaxWidth()) { Column(Modifier.padding(12.dp)) {
            Text("${call.mediaKind} · ${call.status} · ${call.startedAt}")
            Text(call.endReason ?: "No end reason reported")
            if (call.status == "active" && runCatching { java.time.Instant.parse(call.expiresAt) > java.time.Instant.now() }.getOrDefault(false))
                Button(onClick = { join(call) }, enabled = !state.busy) { Text("Join current call") }
        } } }
        if (state.callsCursor != null) item { TextButton(onClick = controller::moreCalls, enabled = !state.busy) { Text("Load more calls") } }
    }
}

@Composable private fun Meetings(state: AppState, controller: AppController, start: (Meeting, MeetingOccurrence) -> Unit) {
    LazyColumn(Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        item { Text("Meetings · yesterday through next week", style = MaterialTheme.typography.titleLarge) }
        items(state.meetings, key = { it.id }) { meeting -> Card(Modifier.fillMaxWidth()) { Column(Modifier.padding(12.dp)) {
            Text(meeting.title, style = MaterialTheme.typography.titleMedium)
            Text("${meeting.localStart} · ${meeting.timezone} · ${meeting.durationMinutes} minutes · ${meeting.status}")
            meeting.occurrences.forEach { occurrence ->
                Text("${occurrence.startsAt} · ${occurrence.status}")
                if (meeting.status != "cancelled" && occurrence.status != "cancelled") Button(onClick = { start(meeting, occurrence) }, enabled = !state.busy) { Text("Start or join occurrence ${occurrence.sequence}") }
            }
            if (meeting.canManage && meeting.status != "cancelled") TextButton(onClick = { controller.cancelMeeting(meeting) }, enabled = !state.busy) { Text("Cancel meeting") }
        } } }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable private fun Phone(state: AppState, controller: AppController, dial: (String) -> Unit, answer: (PhoneCall, Boolean) -> Unit) {
    var number by remember(state.identity?.lease) { mutableStateOf("") }
    val configuration = state.phoneConfiguration
    val ready = configuration?.enabled == true && configuration.configured && configuration.providerReady != false && configuration.lineAssigned != false && configuration.number != null
    val media by controller.media.state.collectAsStateWithLifecycle()
    LazyColumn(Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        item {
            Text("Phone", style = MaterialTheme.typography.titleLarge)
            Text(if (ready) "Phone calling is configured and a line is assigned. Calls depend on phone service availability." else "Phone is unavailable until the workspace provider and assigned line are configured.")
            Text("${configuration?.number?.phoneNumber ?: "No line assigned"}")
            Field("International destination", number, { number = it }, "+441234567890")
            Button(onClick = { dial(number) }, enabled = ready && !state.busy && Regex("\\+[1-9]\\d{7,14}").matches(number)) { Text("Dial") }
            state.pendingDialDestination?.let { pending ->
                Text("The dial result is uncertain. Check call history or retry the same command before starting another call.")
                TextButton(onClick = { dial(pending) }, enabled = ready && !state.busy) { Text("Retry pending dial to $pending") }
            }
            if (media.phoneCallId != null && state.phoneCapabilities?.dtmf?.supported == true) {
                Text("DTMF: authorization → SDK → completion. Carrier delivery may remain unknown.")
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) { "123456789*0#".forEach { digit ->
                    OutlinedButton(onClick = { controller.dtmf(digit) }, enabled = !state.busy && media.phase == MediaPhase.CONNECTED) { Text(digit.toString()) }
                } }
            }
            state.phoneControl?.let { receipt ->
                Text("Last control: ${receipt.status}. Reconciliation does not resend the digit.")
                TextButton(onClick = controller::reconcilePhoneControl, enabled = !state.busy) { Text("Reconcile control receipt") }
            }
        }
        items(state.phoneCalls, key = { it.id }) { call -> Card(Modifier.fillMaxWidth()) { Column(Modifier.padding(12.dp)) {
            Text("${if (call.direction == "inbound") call.fromNumber else call.toNumber} · ${call.direction} · ${call.status}")
            Text("${call.startedAt} · ${call.connectedSeconds}s observed connected duration${if (call.endReason == "answer_unconfirmed") " · answer unconfirmed" else ""}")
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (call.canAnswer) Button(onClick = { answer(call, false) }, enabled = !state.busy) { Text("Answer") }
                if (call.canJoin) Button(onClick = { answer(call, true) }, enabled = !state.busy) { Text("Join") }
                if (call.canAnswer) TextButton(onClick = { controller.rejectPhone(call) }, enabled = !state.busy) { Text("Reject") }
                if (call.canEnd) TextButton(onClick = { controller.endPhone(call) }, enabled = !state.busy) { Text("End phone call") }
            }
        } } }
        if (state.phoneCursor != null) item { TextButton(onClick = controller::morePhoneCalls, enabled = !state.busy) { Text("Load more phone history") } }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable private fun MediaControls(controller: AppController, onCamera: () -> Unit) {
    val media by controller.media.state.collectAsStateWithLifecycle()
    val tiles by controller.media.videoTiles.collectAsStateWithLifecycle()
    Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text("Call ${media.phase.name.lowercase()}", style = MaterialTheme.typography.titleMedium)
        media.error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Button(onClick = { controller.microphone(!media.microphoneEnabled) }, enabled = media.phase == MediaPhase.CONNECTED) { Text(if (media.microphoneEnabled) "Mute microphone" else "Enable microphone") }
            if (media.video) Button(onClick = onCamera, enabled = media.phase == MediaPhase.CONNECTED) { Text(if (media.cameraEnabled) "Disable camera" else "Enable camera") }
            Button(onClick = controller::endMedia) { Text("Leave / end call") }
        }
        FlowRow(horizontalArrangement = Arrangement.spacedBy(4.dp)) { media.endpoints.forEach { endpoint ->
            FilterChip(selected = media.currentEndpointId == endpoint.id, onClick = { controller.endpoint(endpoint.id) }, label = { Text(endpoint.label) })
        } }
        if (media.video) Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) { tiles.take(4).forEach { tile ->
            Column(Modifier.width(200.dp)) {
                Text(tile.name, style = MaterialTheme.typography.labelMedium)
                MediaVideo(tile, Modifier.fillMaxWidth().height(140.dp))
            }
        } }
        if (tiles.size > 4) Text("${tiles.size - 4} additional video tracks are connected.", style = MaterialTheme.typography.bodySmall)
    }
}
