import SwiftData
import SwiftUI

/// The Dictation page: greeting, hero banner, history feed and the sticky stats aside.
struct FlowHomeView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var history = FlowHistoryModel()
    @ObservedObject private var stats = FlowStatsStore.shared

    @State private var shortcutKeys: [String] = FlowHomeView.primaryShortcutKeys()
    @State private var showTryIt = false

    // Sticky aside bookkeeping (all in the page scroll viewport's coordinates).
    @State private var columnFrame: CGRect = .zero
    @State private var asideHeight: CGFloat = 0

    static let maxWidth: CGFloat = 1046
    static let bannerDismissKey = "FlowHomeBannerDismissed"
    private static let stickyTop: CGFloat = 16

    var body: some View {
        FlowPage(maxWidth: Self.maxWidth) {
            title
        } titleAccessory: {
            EmptyView()
        } content: {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 24) {
                    banner
                    FlowHistoryFeed(model: history)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)

                FlowHomeAside()
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        asideHeight = height
                    }
                    .offset(y: asideOffset)
                    .frame(width: FlowHomeAside.width, alignment: .top)
                    .zIndex(1)
            }
            // The row is as tall as the feed; the aside may slide within it.
            .background {
                Color.clear
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .named(FlowPageSpace.scroll))
                    } action: { frame in
                        columnFrame = frame
                    }
            }
        }
        .onAppear {
            history.attach(modelContext)
            shortcutKeys = Self.primaryShortcutKeys()
        }
        .onReceive(NotificationCenter.default.publisher(for: ShortcutStore.shortcutDidChange)) { _ in
            shortcutKeys = Self.primaryShortcutKeys()
        }
        .sheet(isPresented: $showTryIt) {
            FlowTryItSheet()
        }
    }

    // MARK: - Title

    @ViewBuilder
    private var title: some View {
        let name = FlowUser.firstName
        if stats.summary.totalWords >= 2000 {
            Text("Welcome back, \(name)")
        } else if shortcutKeys.isEmpty {
            Text("Hey \(name), get back into the flow")
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Hey \(name), get back into the flow with")
                    .lineLimit(1)
                FlowKeycap(keys: shortcutKeys, inline: true, fontSize: 18)
                    .fixedSize()
            }
        }
    }

    // MARK: - Banner

    private var bannerTitle: String {
        guard !shortcutKeys.isEmpty else { return "Hold down your shortcut to dictate" }
        let key = shortcutKeys.joined(separator: " + ")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "_", with: " ")
        return "Hold down **\(key)** to dictate"
    }

    private var banner: some View {
        FlowBanner(
            title: bannerTitle,
            description: "Free Flow works in all your apps. Try it in **email, messages, docs** or anywhere else.",
            dismissKey: Self.bannerDismissKey
        ) {
            Button("See how it works") { showTryIt = true }
                .buttonStyle(FlowButtonStyle(variant: .secondary))
        }
    }

    // MARK: - Sticky aside

    /// Keeps the aside pinned near the top of the viewport while the feed scrolls,
    /// without letting it run past the bottom of the feed column.
    private var asideOffset: CGFloat {
        let wanted = Self.stickyTop - columnFrame.minY
        let maximum = max(0, columnFrame.height - asideHeight)
        return min(max(0, wanted), maximum)
    }

    // MARK: - Shortcut

    static func primaryShortcutKeys() -> [String] {
        ShortcutStore.shortcut(for: .primaryRecording)?.displayTokens ?? []
    }
}
