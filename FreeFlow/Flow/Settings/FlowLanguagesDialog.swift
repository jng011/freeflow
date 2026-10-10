import SwiftUI

struct FlowLanguagesDialog: View {
    let onClose: () -> Void

    @State private var selection: [String] = FlowLanguageCatalog.storedSelection
    @State private var autoDetect = FlowLanguageCatalog.isAutoDetect
    @State private var error: String?

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Dictation languages")
                        .flowText(.h4)
                        .foregroundStyle(FlowColor.foreground)
                    Text("Choose the languages you want to dictate in.")
                        .flowText(.md)
                        .foregroundStyle(FlowColor.neutral600)
                        .frame(maxWidth: 560, alignment: .leading)
                }
                Spacer(minLength: 16)
                FlowAutoDetectSwitch(isOn: $autoDetect)
            }

            FlowLanguagePicker(selection: $selection, autoDetect: autoDetect, gridHeight: 413)

            HStack(spacing: 12) {
                if let error {
                    Text(error)
                        .font(FlowFont.sans(12))
                        .foregroundStyle(FlowColor.destructive)
                }
                Spacer(minLength: 12)
                Button("Save and close", action: save)
                    .flowSettingsButton(.primary)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minHeight: 548)
        .fixedSize()
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(FlowColor.background))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(FlowColor.border, lineWidth: 1))
        .flowShadow(.xl)
        .onChange(of: selection) { _, _ in error = nil }
        .onChange(of: autoDetect) { _, _ in error = nil }
    }

    private func save() {
        guard autoDetect || !selection.isEmpty else {
            error = "Please select at least one language or turn on auto-detect"
            return
        }
        FlowLanguageCatalog.save(selection: selection, autoDetect: autoDetect)
        onClose()
    }
}

/// "Auto-detect" switch with the "99 languages" caption.
struct FlowAutoDetectSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .trailing, spacing: 0) {
                Text("Auto-detect")
                    .flowText(.smEmph)
                    .foregroundStyle(FlowColor.foreground)
                Text("\(FlowLanguageCatalog.autoDetectCount) languages")
                    .flowText(.xs)
                    .foregroundStyle(FlowColor.foregroundTertiary)
            }
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(FlowSettingsSwitchStyle())
        }
    }
}

/// Searchable 3-column language grid (560 wide) plus the 224 wide "Selected" list.
struct FlowLanguagePicker: View {
    @Binding var selection: [String]
    var autoDetect: Bool
    var gridHeight: CGFloat = 413
    var showsSelectedList = true
    var gridWidth: CGFloat = 560
    var columnCount = 3

    @State private var query = ""

    private var filtered: [FlowLanguage] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return FlowLanguageCatalog.all }
        return FlowLanguageCatalog.all.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed)
                || $0.nativeName.localizedCaseInsensitiveContains(trimmed)
                || $0.code.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    FlowSettingsIcon(name: "search", size: 16, stroke: 1.5, color: FlowColor.foregroundTertiary, fallback: "magnifyingglass")
                    TextField(
                        "",
                        text: $query,
                        prompt: Text("Search for any languages").foregroundStyle(FlowColor.foregroundTertiary)
                    )
                    .textFieldStyle(.plain)
                    .font(FlowFont.sans(15))
                }
                .padding(12)
                Rectangle().fill(FlowColor.border).frame(height: 1)
                ScrollView {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: max(1, columnCount)),
                        spacing: 12
                    ) {
                        ForEach(filtered) { language in
                            FlowLanguageTile(language: language, isSelected: selection.contains(language.code)) {
                                toggle(language.code)
                            }
                        }
                    }
                    .padding(12)
                }
                .scrollIndicators(.hidden)
            }
            .frame(width: gridWidth, height: gridHeight)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(FlowColor.border, lineWidth: 1))
            .opacity(autoDetect ? 0.5 : 1)
            .disabled(autoDetect)

            if showsSelectedList {
                selectedList
            }
        }
    }

    private var selectedList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Selected")
                .font(FlowFont.sans(12, weight: 600))
                .foregroundStyle(FlowColor.neutral500)
            if autoDetect {
                Text("Auto-detect is on")
                    .font(FlowFont.sans(12))
                    .foregroundStyle(FlowColor.foregroundTertiary)
            } else if selection.isEmpty {
                Text("No languages yet")
                    .font(FlowFont.sans(12))
                    .foregroundStyle(FlowColor.foregroundTertiary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(selection, id: \.self) { code in
                            HStack(spacing: 8) {
                                Text(FlowLanguageCatalog.name(for: code))
                                    .font(FlowFont.sans(12))
                                    .foregroundStyle(FlowColor.foreground)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Button {
                                    selection.removeAll { $0 == code }
                                } label: {
                                    FlowSettingsIcon(name: "x", size: 14, stroke: 1.75, color: FlowColor.neutral500, fallback: "xmark")
                                        .frame(width: 24, height: 24)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("Remove")
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .frame(width: 224, alignment: .topLeading)
        .frame(maxHeight: gridHeight, alignment: .top)
    }

    private func toggle(_ code: String) {
        if let index = selection.firstIndex(of: code) {
            selection.remove(at: index)
        } else {
            selection.append(code)
        }
    }
}

private struct FlowLanguageTile: View {
    let language: FlowLanguage
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                Text(language.name)
                    .font(FlowFont.sans(15, weight: 600))
                    .foregroundStyle(FlowColor.foreground)
                    .lineLimit(1)
                Text(language.nativeName)
                    .font(FlowFont.sans(12))
                    .foregroundStyle(FlowColor.foregroundTertiary)
                    .lineLimit(1)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? FlowSettingsPalette.selectedTileFill : (isHovered ? FlowColor.neutral200 : FlowColor.backgroundTertiary))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSelected ? FlowSettingsPalette.dawn700 : Color.clear, lineWidth: 2)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
