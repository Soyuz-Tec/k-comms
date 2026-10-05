import SwiftUI
import LiveKit

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var tab = 0
    var body: some View {
        Group {
            if model.restoring { ProgressView("Checking your session…") }
            else if model.session == nil { SignInView() }
            else {
                TabView(selection: $tab) {
                    ChatsView().tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }.tag(0)
                    if model.hasWorkspaceAccess {
                        PeopleView(onConversation: { tab = 0 }).tabItem { Label("People", systemImage: "person.2") }.tag(1)
                        MeetingsView().tabItem { Label("Meetings", systemImage: "calendar") }.tag(2)
                        PhoneView(model: model.phone).tabItem { Label("Phone", systemImage: "phone") }.tag(3)
                    }
                    SettingsView().tabItem { Label("You", systemImage: "person.crop.circle") }.tag(4)
                }
                .onChange(of: model.hasWorkspaceAccess) { allowed in if !allowed { tab = 0 } }
                .safeAreaInset(edge: .top) {
                    if let status = model.statusMessage {
                        HStack { Text(status).font(.callout); Spacer(); Button("Dismiss") { model.statusMessage = nil } }
                            .padding().background(.thinMaterial).accessibilityElement(children: .contain)
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    if let call = model.activeCall { CallControls(call: call, media: model.media).padding().background(.regularMaterial) }
                    else { PhoneCallOverlay(model: model.phone).background(.regularMaterial) }
                }
            }
        }
    }
}

private struct SignInView: View {
    @EnvironmentObject private var model: AppModel
    @State private var tenant = ""
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    var body: some View {
        NavigationStack {
            Form {
                Section { Text("K-Comms").font(.largeTitle.bold()); Text("Sign in to your workspace.") }
                Section { Text(NativeIdentityAvailability.corporateSignIn).font(.caption).foregroundStyle(.secondary) }
                if model.mfaChallenge != nil {
                    Section("Authenticator verification") {
                        TextField("Authenticator or recovery code", text: $code).textContentType(.oneTimeCode).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Verify") { let input = code; code = ""; Task { await model.verifyMfa(input) } }.disabled(code.isEmpty || model.busy)
                        Button("Back to sign in") { code = ""; Task { await model.cancelMfa() } }
                    }
                } else {
                    Section("Server and workspace") {
                        TextField("Server, for example https://comms.example.org", text: $model.serverInput)
                            .keyboardType(.URL).textContentType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("Workspace slug", text: $tenant).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    Section("Your account") {
                        TextField("Email", text: $email).keyboardType(.emailAddress).textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("Password", text: $password).textContentType(.password)
                        Button("Sign in") {
                            let input = password; password = ""
                            Task { await model.signIn(tenant: tenant, email: email, password: input) }
                        }.disabled(model.busy || password.isEmpty || tenant.isEmpty || email.isEmpty || model.serverInput.isEmpty)
                    }
                }
                if model.busy { ProgressView("Signing in…") }
                if let status = model.statusMessage { Section { Text(status).foregroundStyle(.secondary) } }
            }.navigationTitle("Welcome")
        }
    }
}

private struct ChatsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var path: [String] = []
    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section { Label(model.connectionLabel, systemImage: "network").font(.caption).foregroundStyle(.secondary) }
                ForEach(model.conversations) { conversation in
                    Button { Task { await model.select(conversation) } } label: {
                        HStack {
                            Image(systemName: conversation.kind == "direct" ? "person.crop.circle" : "person.3").foregroundStyle(.tint)
                            Text(conversation.label).foregroundStyle(.primary); Spacer()
                            if let unread = conversation.unreadCount, unread > 0 { Text(String(unread)).font(.caption.bold()).padding(7).background(.tint.opacity(0.15), in: Capsule()) }
                        }.padding(.vertical, 5)
                    }
                }
                if model.conversations.isEmpty { Text("No conversations yet. Find someone in People to start a chat.").foregroundStyle(.secondary) }
            }
            .navigationTitle("Chat").refreshable { await model.refreshWorkspace() }
            .toolbar { Button { Task { await model.refreshWorkspace() } } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Refresh conversations") }
            .navigationDestination(for: String.self) { _ in ChatScreen() }
            .onChange(of: model.selectedConversation?.id) { id in path = id.map { [$0] } ?? [] }
            .onChange(of: path) { value in if value.isEmpty && model.selectedConversation != nil { Task { await model.select(nil) } } }
        }
    }
}

private struct ChatScreen: View {
    @EnvironmentObject private var model: AppModel
    @State private var draft = ""
    @State private var editing: Message?
    @State private var editBody = ""
    @State private var deleting: Message?
    var body: some View {
        ScrollViewReader { proxy in
            List {
                Button("Load earlier messages") { Task { await model.loadEarlier() } }.disabled(!model.hasEarlierMessages)
                ForEach(model.messages) { message in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(message.senderUserId == model.session?.user.id ? "You" : (model.senderLabels[message.senderUserId]?.displayName ?? "Member")).font(.caption.bold())
                            Spacer(); Text(Wire.date(message.insertedAt)?.formatted(date: .omitted, time: .shortened) ?? "").font(.caption).foregroundStyle(.secondary)
                        }
                        Text(message.visibleBody).textSelection(.enabled)
                        if message.status == "active" {
                            ForEach(message.attachments) { attachment in
                                Label("\(attachment.fileName) · \(attachment.status == "ready" ? "Open on the web to download" : "Processing or unavailable")", systemImage: "paperclip")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if message.editedAt != nil { Text("Edited").font(.caption2).foregroundStyle(.secondary) }
                        }
                    }.padding(.vertical, 5).id(message.id)
                        .contextMenu {
                            if message.status == "active" && message.senderUserId == model.session?.user.id {
                                Button("Edit") { editing = message; editBody = message.body ?? "" }
                                Button("Delete", role: .destructive) { deleting = message }
                            }
                        }
                }
                ForEach(model.pendingMessages.filter { $0.conversation == model.selectedConversation?.id }) { pending in
                    VStack(alignment: .leading) {
                        Text(pending.body).foregroundStyle(.secondary)
                        Text("Delivery not confirmed").font(.caption)
                        HStack { Button("Retry") { Task { await model.retry(pending) } }; Button("Discard", role: .destructive) { model.discard(pending) } }
                    }
                }
                if model.messageHasMore { Button("Load more messages") { Task { await model.loadMore() } } }
                if let call = model.availableCall, model.activeCall == nil {
                    Button("Join available \(call.isVideo ? "video" : "audio") call") { Task { await model.startCall(video: call.isVideo, joinExisting: true) } }
                }
            }
            .onChange(of: model.messages.last?.id) { id in
                if let id { withAnimation { proxy.scrollTo(id, anchor: .bottom) }; Task { await model.markVisibleRead() } }
            }
            .refreshable { await model.catchUp() }
        }
        .navigationTitle(model.selectedConversation?.label ?? "Conversation")
        .toolbar {
            if model.activeCall == nil {
                if model.me?.capabilities.allowAudioCalls == true { Button { Task { await model.startCall(video: false) } } label: { Image(systemName: "phone") }.accessibilityLabel("Start audio call") }
                if model.me?.capabilities.allowVideoCalls == true { Button { Task { await model.startCall(video: true) } } label: { Image(systemName: "video") }.accessibilityLabel("Start video call") }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(alignment: .bottom) {
                TextField("Message", text: $draft, axis: .vertical).lineLimit(1...5).textFieldStyle(.roundedBorder)
                Button("Send") { let body = draft; draft = ""; Task { await model.send(body) } }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding().background(.regularMaterial)
        }
        .onChange(of: model.session?.identity) { _ in draft = ""; editing = nil; deleting = nil; editBody = "" }
        .sheet(item: $editing) { message in
            NavigationStack { Form { TextField("Message", text: $editBody, axis: .vertical); Button("Save edit") { let body = editBody; editing = nil; editBody = ""; Task { await model.edit(message, body: body) } }.disabled(editBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                .navigationTitle("Edit message").toolbar { Button("Cancel") { editing = nil; editBody = "" } } }
        }
        .confirmationDialog("Delete this message?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete message", role: .destructive) { if let message = deleting { deleting = nil; Task { await model.delete(message) } } }
        }
    }
}

private struct PeopleView: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""
    @State private var selection: Set<String> = []
    @State private var groupTitle = ""
    let onConversation: () -> Void
    var body: some View {
        NavigationStack {
            List {
                Section("Find a teammate") {
                    TextField("Search people", text: $query).textInputAutocapitalization(.never)
                        .onSubmit { Task { selection = []; await model.searchPeople(query) } }
                    Button("Search") { Task { selection = []; await model.searchPeople(query) } }
                }
                ForEach(model.directory) { person in
                    HStack {
                        Toggle(isOn: Binding(get: { selection.contains(person.id) }, set: { selected in if selected { selection.insert(person.id) } else { selection.remove(person.id) } })) { Text(person.displayName) }
                        Button("Chat") { Task { await model.openDirect(person); if model.selectedConversation != nil { onConversation() } } }.buttonStyle(.bordered)
                    }
                }
                if model.directoryCursor != nil { Button("More people") { Task { await model.searchPeople(query, more: true) } } }
                Section("Private group") {
                    TextField("Group name", text: $groupTitle)
                    Button("Create group with \(selection.count) people") {
                        Task { await model.createGroup(title: groupTitle, members: selection); if model.selectedConversation != nil { selection = []; groupTitle = ""; onConversation() } }
                    }.disabled(selection.isEmpty || groupTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.navigationTitle("People").task { await model.searchPeople("") }
                .onChange(of: model.session?.identity) { _ in selection = []; groupTitle = ""; query = "" }
        }
    }
}

private struct MeetingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showCreate = false
    var body: some View {
        NavigationStack {
            List {
                Section { Text("Next seven days. Times are shown in your device time zone.").font(.caption).foregroundStyle(.secondary) }
                ForEach(model.meetings.filter { $0.status == "scheduled" }) { meeting in
                    Section(meeting.title) {
                        Text("Meeting time zone: \(meeting.timezone)").font(.caption).foregroundStyle(.secondary)
                        ForEach(meeting.occurrences.filter { $0.status == "scheduled" }) { occurrence in
                            VStack(alignment: .leading) {
                                Text(Wire.date(occurrence.startsAt)?.formatted(date: .abbreviated, time: .shortened) ?? "Time unavailable")
                                HStack {
                                    if model.me?.capabilities.allowAudioCalls == true { Button(meeting.canManage ? "Start audio" : "Join audio") { Task { await model.startMeeting(meeting, occurrence: occurrence, video: false) } } }
                                    if model.me?.capabilities.allowVideoCalls == true { Button(meeting.canManage ? "Start video" : "Join video") { Task { await model.startMeeting(meeting, occurrence: occurrence, video: true) } } }
                                }.disabled(model.activeCall != nil || (Wire.date(occurrence.endsAt) ?? .distantPast) <= Date())
                            }
                        }
                        if meeting.canManage { Button("Cancel meeting", role: .destructive) { Task { await model.cancelMeeting(meeting) } } }
                    }
                }
                if model.meetings.isEmpty { Text("No scheduled meetings in this window.").foregroundStyle(.secondary) }
            }.navigationTitle("Meetings").task { await model.refreshMeetings() }.refreshable { await model.refreshMeetings() }
                .toolbar { Button("Schedule") { showCreate = true }.disabled(model.conversations.isEmpty) }
                .sheet(isPresented: $showCreate) { CreateMeetingView() }
        }
    }
}
private struct CreateMeetingView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var conversation = ""
    @State private var title = ""
    @State private var start = Date().addingTimeInterval(3600)
    @State private var duration = 30
    var body: some View {
        NavigationStack {
            Form {
                Picker("Conversation", selection: $conversation) { Text("Choose a conversation").tag(""); ForEach(model.conversations) { Text($0.label).tag($0.id) } }
                TextField("Meeting title", text: $title)
                DatePicker("Starts", selection: $start, in: Date()...)
                Text("Time zone: \(TimeZone.current.identifier)").font(.caption)
                Stepper("\(duration) minutes", value: $duration, in: 5...480, step: 5)
                Button("Schedule meeting") { let selected = conversation; let name = title; let when = start; let minutes = duration; dismiss(); Task { await model.createMeeting(conversation: selected, title: name, start: when, duration: minutes) } }
                    .disabled(conversation.isEmpty || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.navigationTitle("Schedule meeting").toolbar { Button("Cancel") { dismiss() } }
        }
    }
}

private struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        NavigationStack {
            Form {
                Section("Your account") {
                    Text(model.session?.user.displayName ?? "Member")
                    Text(model.session?.tenant.name ?? "Workspace").foregroundStyle(.secondary)
                    Text(model.serverInput).font(.caption).foregroundStyle(.secondary)
                    if !model.hasWorkspaceAccess { Text("This account can communicate in its available conversations. Workspace directory, meetings and phone require workspace access.").font(.caption).foregroundStyle(.secondary) }
                }
                Section("Calls") { Text(NativePushAvailability.explanation).font(.callout).foregroundStyle(.secondary) }
                Section("Workspace administration") { Text(NativeIdentityAvailability.administrativeProof).font(.callout).foregroundStyle(.secondary) }
                Section { Button("Sign out", role: .destructive) { Task { await model.logout() } } }
            }.navigationTitle("You")
        }
    }
}

private struct CallControls: View {
    @EnvironmentObject private var model: AppModel
    let call: Call
    @ObservedObject var media: CallMedia
    @State private var showVideo = false
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Label(media.connectionLabel, systemImage: call.isVideo ? "video.fill" : "phone.fill").font(.caption)
                Spacer()
                if call.isVideo { Button("Video") { showVideo = true } }
                Button(media.microphoneEnabled ? "Mute" : "Unmute") { Task { await model.toggleMicrophone() } }
                if call.isVideo { Button(media.cameraEnabled ? "Camera off" : "Camera on") { Task { await model.toggleCamera() } } }
                Button("Leave", role: .destructive) { Task { await model.leaveCall() } }
            }.buttonStyle(.bordered)
            if call.canEnd { Button("End for everyone", role: .destructive) { Task { await model.endCallForEveryone() } }.font(.caption) }
        }.sheet(isPresented: $showVideo) {
            NavigationStack { Group { if let room = media.room { RoomTiles(room: room) } else { ProgressView("Connecting…") } }
                .navigationTitle("Call").toolbar { Button("Done") { showVideo = false } } }
        }
    }
}
private struct RoomTiles: View {
    @ObservedObject var room: Room
    private var participants: [Participant] { [room.localParticipant as Participant] + room.remoteParticipants.values.map { $0 as Participant } }
    var body: some View {
        ScrollView { LazyVGrid(columns: [GridItem(.adaptive(minimum: 160))], spacing: 12) {
            ForEach(Array(participants.enumerated()), id: \.offset) { _, participant in ParticipantTile(participant: participant) }
        }.padding() }
    }
}
private struct ParticipantTile: View {
    @ObservedObject var participant: Participant
    var body: some View {
        VStack {
            if let track = participant.firstCameraVideoTrack { SwiftUIVideoView(track).frame(height: 190).clipShape(RoundedRectangle(cornerRadius: 12)) }
            else { Image(systemName: "person.crop.circle.fill").font(.system(size: 70)).frame(height: 190).foregroundStyle(.secondary) }
            Text(participant.name ?? "Participant").font(.caption).lineLimit(1)
        }.accessibilityElement(children: .combine)
    }
}
