import SwiftUI

struct ModeSettingsQuickSwitchTip: View {
    let onDismiss: () -> Void

    var body: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "keyboard")
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Mode shortcuts")
                        .font(.headline)
                        .lineLimit(1)

                    Text("During recording, press Option + 1-9 to switch modes quickly.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Dismiss")
                .accessibilityLabel("Dismiss shortcut tip")
            }
            .padding(4)
        }
    }
}
