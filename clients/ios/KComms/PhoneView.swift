import SwiftUI

struct PhoneView: View {
    @ObservedObject var model: PhoneModel
    @State private var destination = ""
    var body: some View {
        NavigationStack {
            List {
                Section("Phone availability") {
                    Text(model.configuration?.advice ?? "Refresh to check phone availability.")
                    if let number = model.configuration?.number { Text("\(number.phoneNumber) · extension \(number.extension)").font(.caption) }
                    Text(NativePushAvailability.explanation).font(.caption).foregroundStyle(.secondary)
                    Button("Refresh availability and history") { Task { await model.refresh() } }
                }
                Section("Dial") {
                    TextField("International number, for example +14155550123", text: $destination).keyboardType(.phonePad)
                    Button("Call") { Task { await model.dial(destination) } }.disabled(model.configuration?.canCall != true || model.busy || model.active != nil || destination.isEmpty)
                    Text("If a dial result is uncertain, refresh history before retrying. The same destination retains its operation key until confirmed.").font(.caption).foregroundStyle(.secondary)
                }
                if let notice = model.notice { Section { Text(notice).accessibilityLabel("Phone status: \(notice)") } }
                Section("Call history") {
                    ForEach(model.history) { call in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(call.otherNumber).font(.headline)
                            Text("\(call.direction.capitalized) · \(call.statusLabel)").font(.caption)
                            Text(Wire.date(call.startedAt)?.formatted(date: .abbreviated, time: .shortened) ?? "Time unavailable").font(.caption).foregroundStyle(.secondary)
                            Text(call.endReason == "answer_unconfirmed" ? "Duration unconfirmed" : "\(call.connectedSeconds)s connected").font(.caption)
                            HStack {
                                if call.canAnswer { Button("Answer") { Task { await model.admit(call, answer: true) } }; Button("Decline", role: .destructive) { Task { await model.reject(call) } } }
                                if call.canJoin && !call.canAnswer { Button("Join") { Task { await model.admit(call, answer: false) } } }
                            }.disabled(model.busy || model.active != nil)
                        }.padding(.vertical, 4)
                    }
                    if model.history.isEmpty { Text("No retained phone calls.").foregroundStyle(.secondary) }
                    if model.nextCursor != nil { Button("More calls") { Task { await model.refresh(more: true) } } }
                }
            }.navigationTitle("Phone").task { await model.refresh() }.refreshable { await model.refresh() }
        }
    }
}
struct PhoneCallOverlay: View {
    @ObservedObject var model: PhoneModel
    var body: some View { if let active = model.active { PhoneCallControls(model: model, media: model.media, call: active) } }
}
private struct PhoneCallControls: View {
    @ObservedObject var model: PhoneModel
    @ObservedObject var media: CallMedia
    let call: PhoneCall
    @State private var keypad = false
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("\(call.otherNumber) · \(media.connectionLabel)").font(.caption)
                Spacer()
                Button(media.microphoneEnabled ? "Mute" : "Unmute") { Task { await model.toggleMicrophone() } }
                Button("Keypad") { keypad = true }.disabled(model.capabilities["dtmf"]?.supported != true)
                if call.canEnd { Button("End", role: .destructive) { Task { await model.end() } } }
                Button("Leave", role: .destructive) { Task { await model.leave() } }
            }.buttonStyle(.bordered)
        }.padding().sheet(isPresented: $keypad) {
            NavigationStack {
                List {
                    Section("In-call keypad") {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3)) {
                            ForEach(Array("123456789*0#").map(String.init), id: \.self) { digit in
                                Button(digit) { Task { await model.sendTone(digit) } }.frame(minWidth: 44, minHeight: 44).disabled(!model.canSendTone).accessibilityLabel("Send tone \(digit)")
                            }
                        }
                    }
                    if let notice = model.notice { Text(notice) }
                    if model.hasPendingTone { Button("Review pending tone receipt") { Task { await model.reconcilePendingTone() } }.disabled(model.busy) }
                    Section("Retained control receipts") { ForEach(model.receipts) { receipt in Text("\(receipt.action) · \(receipt.status)") } }
                }.navigationTitle("Keypad").toolbar { Button("Done") { keypad = false } }
            }
        }
    }
}
