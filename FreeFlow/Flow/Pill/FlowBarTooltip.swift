import SwiftUI

/// Text of the capsule tooltip above the pill. `key` renders in weight 600.
struct FlowBarTooltipContent: Equatable {
    var leading: String
    var key: String?
    var trailing: String
    /// Button tooltips sit 10 pt above the pill instead of 4.
    var isButton: Bool

    static func dictate(key: String) -> FlowBarTooltipContent {
        FlowBarTooltipContent(leading: "Dictate ", key: key, trailing: "", isButton: false)
    }

    static func handsFree(key: String) -> FlowBarTooltipContent {
        FlowBarTooltipContent(leading: "Press ", key: key, trailing: " to finish and paste", isButton: false)
    }

    static let cancel = FlowBarTooltipContent(leading: "Cancel", key: nil, trailing: "", isButton: true)
    static let finish = FlowBarTooltipContent(leading: "Finish and paste", key: nil, trailing: "", isButton: true)
}

/// Black capsule tooltip, no arrow.
struct FlowBarTooltip: View {
    let content: FlowBarTooltipContent

    var body: some View {
        label
            .foregroundStyle(Color.white)
            .lineLimit(1)
            .fixedSize()
            .padding(.vertical, 6)
            .padding(.horizontal, 14)
            .background(
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .fill(FlowBarPalette.black)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .strokeBorder(FlowBarPalette.border, lineWidth: 1)
            )
            .allowsHitTesting(false)
    }

    private var label: Text {
        var text = Text(content.leading).font(FlowFont.sans(15, weight: 400))
        if let key = content.key {
            text = text + Text(key).font(FlowFont.sans(15, weight: 600))
        }
        if !content.trailing.isEmpty {
            text = text + Text(content.trailing).font(FlowFont.sans(15, weight: 400))
        }
        return text
    }
}
