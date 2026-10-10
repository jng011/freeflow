import SwiftUI

/// Named coordinate space of the page card's scroll viewport, for sticky asides.
enum FlowPageSpace {
    static let scroll = "FlowPageScroll"
}

/// The inset page card that holds every destination.
/// Sits 0 left (against the sidebar), 8 right, 8 bottom, 0 top (under the title bar).
struct FlowPage<Title: View, Accessory: View, Content: View>: View {
    let maxWidth: CGFloat?
    let scrolls: Bool
    let title: Title
    let accessory: Accessory
    let content: Content

    /// Custom title view (for example a title with an inline keycap).
    init(
        maxWidth: CGFloat? = nil,
        scrolls: Bool = true,
        @ViewBuilder titleView: () -> Title,
        @ViewBuilder titleAccessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) {
        self.maxWidth = maxWidth
        self.scrolls = scrolls
        self.title = titleView()
        self.accessory = titleAccessory()
        self.content = content()
    }

    private static var sidebarWidthEstimate: CGFloat { 216 }

    var body: some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: FlowRadius.page,
            bottomLeadingRadius: FlowRadius.lg,
            bottomTrailingRadius: FlowRadius.lg,
            topTrailingRadius: FlowRadius.page,
            style: .continuous
        )

        GeometryReader { geometry in
            let available = max(0, geometry.size.width - 80)
            let resolvedMax = maxWidth ?? max(800, (geometry.size.width + Self.sidebarWidthEstimate) * 0.5)
            let columnWidth = min(resolvedMax, available)

            if scrolls {
                ScrollView(.vertical) {
                    column
                        .frame(width: columnWidth, alignment: .topLeading)
                        .padding(.top, 40)
                        .padding(.bottom, 40)
                        .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)
                .coordinateSpace(name: FlowPageSpace.scroll)
            } else {
                column
                    .frame(width: columnWidth, alignment: .topLeading)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 40)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .background(shape.fill(FlowColor.background))
        .clipShape(shape)
        .overlay(shape.strokeBorder(FlowColor.border, lineWidth: 1))
        .padding(.trailing, 8)
        .padding(.bottom, 8)
    }

    private var column: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .center, spacing: 16) {
                    title
                        .flowText(.h1)
                        .foregroundStyle(FlowColor.foreground)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    accessory
                }
            }
            .padding(.bottom, 24)
            content
                .frame(maxWidth: .infinity, maxHeight: scrolls ? nil : .infinity, alignment: .topLeading)
        }
    }
}

extension FlowPage where Title == Text {
    /// FlowPage(title:titleAccessory:maxWidth:content:)
    init(
        title: String,
        @ViewBuilder titleAccessory: () -> Accessory,
        maxWidth: CGFloat? = nil,
        scrolls: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.init(maxWidth: maxWidth, scrolls: scrolls, titleView: { Text(title) }, titleAccessory: titleAccessory, content: content)
    }

    /// FlowPage(title:maxWidth:titleAccessory:content:) with an explicit width.
    init(
        title: String,
        maxWidth: CGFloat?,
        scrolls: Bool = true,
        @ViewBuilder titleAccessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) {
        self.init(maxWidth: maxWidth, scrolls: scrolls, titleView: { Text(title) }, titleAccessory: titleAccessory, content: content)
    }
}

extension FlowPage where Title == Text, Accessory == EmptyView {
    init(title: String, maxWidth: CGFloat? = nil, scrolls: Bool = true, @ViewBuilder content: () -> Content) {
        self.init(maxWidth: maxWidth, scrolls: scrolls, titleView: { Text(title) }, titleAccessory: { EmptyView() }, content: content)
    }
}
