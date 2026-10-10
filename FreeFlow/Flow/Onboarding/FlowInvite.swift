import SwiftUI

// Invite codes. Only reachable from a hidden gesture (FlowInviteTapTarget). The box
// shows whatever the server sends, so the app itself says nothing about it.

// MARK: - Hidden box

/// Wraps a view so eight taps in a row (each within a second of the last) open the invite box.
struct FlowInviteTapTarget<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var taps: [Date] = []
    @State private var showsInvite = false

    var body: some View {
        content
            .contentShape(Rectangle())
            .onTapGesture {
                let now = Date()
                taps = (taps.last.map { now.timeIntervalSince($0) < 1 } ?? true) ? taps + [now] : [now]
                if taps.count >= 8 {
                    taps = []
                    showsInvite = true
                }
            }
            .sheet(isPresented: $showsInvite) {
                FlowInviteSheet { showsInvite = false }
            }
    }
}

/// The hidden invite box. Its words come from the server; until they arrive it shows a spinner.
struct FlowInviteSheet: View {
    let onClose: () -> Void
    @ObservedObject private var engine = ParleEngine.shared
    @AppStorage(FlowLegacyKeys.displayName) private var displayName = ""
    @State private var prompt: ParleAccessClient.InvitePrompt?
    @State private var failed = false
    @State private var code = ""
    @State private var isWorking = false
    @State private var error: String?
    @State private var done = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let prompt {
                Text(prompt.title)
                    .flowText(.h4)
                    .foregroundStyle(FlowColor.foreground)
                if done {
                    Text("Request sent.")
                        .flowText(.sm)
                        .foregroundStyle(FlowColor.foregroundTertiary)
                } else {
                    Text(prompt.message)
                        .flowText(.sm)
                        .foregroundStyle(FlowColor.foregroundTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    FlowSettingsTextField(placeholder: prompt.placeholder, text: $code, onSubmit: redeem)
                    if let error {
                        Text(error)
                            .flowText(.sm)
                            .foregroundStyle(FlowColor.destructive)
                    }
                }
                HStack {
                    Spacer()
                    Button(done ? "Done" : "Cancel", action: onClose)
                        .flowSettingsButton(.secondary)
                    if !done {
                        Button(isWorking ? "…" : prompt.button, action: redeem)
                            .flowSettingsButton(.primary)
                            .disabled(isWorking || code.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            } else if failed {
                Text("Not available right now.")
                    .flowText(.sm)
                    .foregroundStyle(FlowColor.foregroundTertiary)
                HStack {
                    Spacer()
                    Button("Close", action: onClose).flowSettingsButton(.secondary)
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            }
        }
        .padding(20)
        .frame(width: 340)
        .task {
            do { prompt = try await ParleAccessClient.invitePrompt() } catch { failed = true }
        }
    }

    private func redeem() {
        guard !isWorking else { return }
        isWorking = true
        error = nil
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            error = await engine.redeemInvite(
                code: code, name: name.isEmpty ? ParleAccessClient.defaultRequesterName : name)
            isWorking = false
            done = error == nil
        }
    }
}
