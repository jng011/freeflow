import SwiftUI

// Enhancement Prompt Popover for recorder views
struct EnhancementPromptRow: View {
    let prompt: CustomPrompt
    let isSelected: Bool
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(prompt.title)
                    .foregroundColor(isDisabled ? AppTheme.Text.disabled : AppTheme.Text.primary)
                    .font(.system(size: 13))
                    .lineLimit(1)

                if isSelected {
                    Spacer()
                    Image(systemName: "checkmark")
                        .foregroundColor(isDisabled ? AppTheme.Status.positive.opacity(0.70) : AppTheme.Status.positive)
                        .font(.system(size: 10))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isSelected ? AppTheme.Selection.fill : Color.clear)
        .cornerRadius(4)
    }
}
