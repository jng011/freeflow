import SwiftUI

/// Voice Profile summary for the home aside (the shell places it inside a FlowCardStack section).
struct InsightsHomeVoiceSection: View {
    @ObservedObject private var store = FlowStatsStore.shared
    @ObservedObject private var service = FlowVoiceProfileService.shared
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let profile = service.profile {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Voice Profile")
                        .flowText(.h4)
                        .foregroundStyle(FlowColor.foreground)
                    Text(profile.superpowerTitle)
                        .flowText(.md)
                        .foregroundStyle(FlowColor.foregroundSecondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                InsightsPersonaTile(persona: profile.persona, size: 64, radius: 12, iconSize: 32)
            }
            .contentShape(Rectangle())
            .onTapGesture { openVoiceTab() }
        } else {
            let total = store.summary.totalWords
            let unlock = FlowVoiceProfileService.unlockWords
            let fraction = min(1, Double(max(0, total)) / Double(unlock))
            VStack(alignment: .leading, spacing: 8) {
                Text("Voice Profile")
                    .flowText(.h4)
                    .foregroundStyle(FlowColor.foreground)
                Text(total >= unlock
                     ? "Ready to generate"
                     : "Unlocks in \(InsightsFormat.number(unlock - total)) words")
                    .flowText(.sm)
                    .foregroundStyle(FlowColor.foregroundTertiary)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(colorScheme == .dark ? FlowColor.vast800 : FlowColor.vast100)
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(FlowColor.chord600)
                            .frame(width: geo.size.width * fraction)
                    }
                }
                .frame(height: 6)
            }
            .contentShape(Rectangle())
            .onTapGesture { openVoiceTab() }
        }
    }

    private func openVoiceTab() {
        FlowNavigator.shared.insightsTab = 1
        FlowNavigator.shared.open(.insights)
    }
}
