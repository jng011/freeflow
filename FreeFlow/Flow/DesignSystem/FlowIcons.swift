import SwiftUI

/// Lucide icon names (ISC license). Raw values are the lucide file names.
enum FlowIconName: String, CaseIterable {
    // Navigation and chrome
    case mic
    case chartColumnBig = "chart-column-big"
    case bookText = "book-text"
    case fileVolume = "file-volume"
    case settings
    case panelLeft = "panel-left"

    // Toolbar and list actions
    case search
    case arrowUpDown = "arrow-up-down"
    case refreshCw = "refresh-cw"
    case plus
    case x
    case check
    case copy
    case play
    case pause
    case ellipsisVertical = "ellipsis-vertical"
    case rotateCw = "rotate-cw"
    case trash
    case info
    case circleAlert = "circle-alert"
    case star
    case pencil
    case sparkles
    case externalLink = "external-link"
    case arrowRight = "arrow-right"
    case arrowUpRight = "arrow-up-right"
    case undo2 = "undo-2"
    case loaderCircle = "loader-circle"
    case circleCheck = "circle-check"

    // Insights
    case trendingUp = "trending-up"
    case trendingDown = "trending-down"
    case tvMinimal = "tv-minimal"
    case infinity
    case bot
    case fileText = "file-text"
    case mail
    /// No Lucide equivalent: always the SF Symbol (Ask Siri command).
    case siri
    case messageCircleMore = "message-circle-more"
    case messageSquareText = "message-square-text"
    case chevronLeft = "chevron-left"
    case chevronRight = "chevron-right"
    case chevronDown = "chevron-down"
    case share
    case trophy
    case flame

    // Settings and other
    case slidersHorizontal = "sliders-horizontal"
    case laptop
    case monitor
    case server
    case shieldCheck = "shield-check"
    case sun
    case moon
    case download
    case upload
    case fileUp = "file-up"
    case folder
    case keyboard
    case languages
    case headphones
    case volume2 = "volume-2"
    case lock
    case terminal
    case brain
    case lightbulb
    case penLine = "pen-line"
    case users
    case compass

    /// SF Symbol used when the lucide file is missing from the bundle.
    var sfFallback: String {
        switch self {
        case .mic: return "mic"
        case .chartColumnBig: return "chart.bar.xaxis"
        case .bookText: return "book"
        case .fileVolume: return "waveform.badge.plus"
        case .settings: return "gearshape"
        case .panelLeft: return "sidebar.left"
        case .search: return "magnifyingglass"
        case .arrowUpDown: return "arrow.up.arrow.down"
        case .refreshCw: return "arrow.clockwise"
        case .plus: return "plus"
        case .x: return "xmark"
        case .check: return "checkmark"
        case .copy: return "doc.on.doc"
        case .play: return "play.fill"
        case .pause: return "pause.fill"
        case .ellipsisVertical: return "ellipsis"
        case .rotateCw: return "arrow.clockwise"
        case .trash: return "trash"
        case .info: return "info.circle"
        case .circleAlert: return "exclamationmark.circle"
        case .star: return "star"
        case .pencil: return "pencil"
        case .sparkles: return "sparkles"
        case .externalLink: return "arrow.up.right.square"
        case .arrowRight: return "arrow.right"
        case .arrowUpRight: return "arrow.up.right"
        case .undo2: return "arrow.uturn.backward"
        case .loaderCircle: return "progress.indicator"
        case .circleCheck: return "checkmark.circle"
        case .trendingUp: return "chart.line.uptrend.xyaxis"
        case .trendingDown: return "chart.line.downtrend.xyaxis"
        case .tvMinimal: return "tv"
        case .infinity: return "infinity"
        case .bot: return "cpu"
        case .fileText: return "doc.text"
        case .mail: return "envelope"
        case .siri: return "siri.gen2"
        case .messageCircleMore: return "bubble.left"
        case .messageSquareText: return "text.bubble"
        case .chevronLeft: return "chevron.left"
        case .chevronRight: return "chevron.right"
        case .chevronDown: return "chevron.down"
        case .share: return "square.and.arrow.up"
        case .trophy: return "trophy"
        case .flame: return "flame"
        case .slidersHorizontal: return "slider.horizontal.3"
        case .laptop: return "laptopcomputer"
        case .monitor: return "desktopcomputer"
        case .server: return "macstudio"
        case .shieldCheck: return "checkmark.shield"
        case .sun: return "sun.max"
        case .moon: return "moon"
        case .download: return "arrow.down.to.line"
        case .upload: return "arrow.up.to.line"
        case .fileUp: return "doc.badge.arrow.up"
        case .folder: return "folder"
        case .keyboard: return "keyboard"
        case .languages: return "character.bubble"
        case .headphones: return "headphones"
        case .volume2: return "speaker.wave.2"
        case .lock: return "lock"
        case .terminal: return "terminal"
        case .brain: return "brain"
        case .lightbulb: return "lightbulb"
        case .penLine: return "pencil.line"
        case .users: return "person.2"
        case .compass: return "safari"
        }
    }
}

/// Parsed icon geometry, loaded once per name.
enum FlowIconCache {
    private static let lock = NSLock()
    private static var paths: [FlowIconName: Path] = [:]
    private static var missing: Set<FlowIconName> = []

    static func path(for name: FlowIconName) -> Path? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = paths[name] { return cached }
        if missing.contains(name) { return nil }

        guard let url = FlowResources.url("lucide-\(name.rawValue)", ext: "svg", folder: "Icons"),
            let path = FlowSVGPathParser.path(contentsOf: url)
        else {
            missing.insert(name)
            return nil
        }
        paths[name] = path
        return path
    }
}

/// Scales a 24x24 icon path into its frame.
private struct FlowIconShape: Shape {
    let source: Path

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        let dx = rect.minX + (rect.width - 24 * scale) / 2
        let dy = rect.minY + (rect.height - 24 * scale) / 2
        let transform = CGAffineTransform(translationX: dx, y: dy).scaledBy(x: scale, y: scale)
        return source.applying(transform)
    }
}

/// A Lucide stroke icon. `color` nil uses the current foreground style.
struct FlowIcon: View {
    let name: FlowIconName
    let size: CGFloat
    let stroke: CGFloat
    let color: Color?

    init(_ name: FlowIconName, size: CGFloat = 20, stroke: CGFloat = 2, color: Color? = nil) {
        self.name = name
        self.size = size
        self.stroke = stroke
        self.color = color
    }

    private var strokeStyle: StrokeStyle {
        StrokeStyle(lineWidth: stroke * size / 24, lineCap: .round, lineJoin: .round)
    }

    var body: some View {
        Group {
            if let path = FlowIconCache.path(for: name) {
                if let color {
                    FlowIconShape(source: path).stroke(color, style: strokeStyle)
                } else {
                    FlowIconShape(source: path).stroke(.foreground, style: strokeStyle)
                }
            } else {
                Image(systemName: name.sfFallback)
                    .font(.system(size: size * 0.8, weight: stroke <= 1.5 ? .regular : .medium))
                    .foregroundStyle(color.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.foreground))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
