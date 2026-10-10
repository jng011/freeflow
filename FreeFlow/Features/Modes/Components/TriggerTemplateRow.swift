import SwiftUI

struct TriggerTemplateRow: View {
    let template: TriggerTemplate
    let group: ModeTriggerGroup
    let isAdded: Bool
    let isLoadingApps: Bool
    let onToggle: (ModeTriggerGroup) -> Void

    private var isDisabled: Bool {
        isLoadingApps || (!isAdded && group.isEmpty)
    }

    private var cardBackground: Color {
        isAdded ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor) : Color.clear
    }

    var body: some View {
        Button {
            guard !isDisabled else { return }
            onToggle(group)
        } label: {
            HStack(spacing: 10) {
                TriggerSymbol(systemName: template.systemImage)

                Text(template.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Spacer()

                if !group.isEmpty {
                    TriggerGroupPreviewStack(appConfigs: group.appConfigs, urlConfigs: group.urlConfigs, tileSize: 24)
                        .padding(.trailing, 4)
                }

                if isAdded {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 22, height: 22)
                } else if !isDisabled {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 14, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(cardBackground)
            }
        }
        .buttonStyle(.plain)
        .help(isAdded ? String(localized: "Remove \(template.name) triggers") : group.summaryText)
    }
}

struct TriggerSymbol: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .regular))
            .foregroundStyle(.secondary)
            .frame(width: 24, height: 24)
    }
}
