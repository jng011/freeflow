import SwiftUI

/// Form state of the add / edit dialog. Owned by the Dictionary page so the
/// dialog host's Return key can submit it.
@MainActor
final class FlowDictionaryAddModel: ObservableObject {
    enum Mode: Equatable {
        case add
        case edit(FlowDictionaryEntry)
    }

    @Published var isPresented = false
    @Published private(set) var mode: Mode = .add
    @Published var isReplacement = false {
        didSet { submitError = nil }
    }
    /// The vocabulary word, or the misspelling when `isReplacement` is on.
    @Published var word = "" {
        didSet { submitError = nil }
    }
    @Published var correctSpelling = "" {
        didSet { submitError = nil }
    }
    @Published private(set) var submitError: String?

    private var editingEntry: FlowDictionaryEntry? {
        if case .edit(let entry) = mode { return entry }
        return nil
    }

    var isEditing: Bool { editingEntry != nil }

    func presentAdd(phrase: String = "", replacement: String? = nil) {
        mode = .add
        isReplacement = replacement != nil
        word = phrase
        correctSpelling = replacement ?? ""
        submitError = nil
        isPresented = true
    }

    func presentEdit(_ entry: FlowDictionaryEntry) {
        mode = .edit(entry)
        isReplacement = entry.isReplacement
        word = entry.phrase
        correctSpelling = entry.replacement ?? ""
        submitError = nil
        isPresented = true
    }

    func dismiss() {
        isPresented = false
    }

    // MARK: Validation

    private var trimmedWord: String { word.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedCorrect: String { correctSpelling.trimmingCharacters(in: .whitespacesAndNewlines) }

    var wordTooLong: Bool { trimmedWord.count > FlowDictionaryError.phraseLimit }
    var correctTooLong: Bool { trimmedCorrect.count > FlowDictionaryError.replacementLimit }

    /// Live duplicate check against the dictionary (the entry being edited is allowed).
    var isDuplicate: Bool {
        guard !trimmedWord.isEmpty else { return false }
        let variants = isReplacement ? WordReplacementVariants.parse(trimmedWord) : [trimmedWord]
        let ownVariants = editingEntry?.phraseVariants ?? []
        let terms = FlowDictionaryKnownTerms.shared
        return variants.contains { variant in
            guard !WordReplacementVariants.contains(variant, in: ownVariants) else { return false }
            return terms.isVocabularyWord(variant) || terms.isReplacementSource(variant)
        }
    }

    var inlineError: String? {
        if wordTooLong { return FlowDictionaryError.tooLong.errorDescription }
        if isReplacement && correctTooLong { return FlowDictionaryError.replacementTooLong.errorDescription }
        if isDuplicate { return FlowDictionaryError.duplicate.errorDescription }
        return submitError
    }

    var canSubmit: Bool {
        guard !trimmedWord.isEmpty, !wordTooLong, !isDuplicate else { return false }
        if isReplacement {
            return !trimmedCorrect.isEmpty && !correctTooLong
        }
        return true
    }

    /// Counter text shown only near the limit, for example "52/60".
    var wordCounter: String? {
        let count = trimmedWord.count
        return count >= FlowDictionaryError.phraseLimit - 10 ? "\(count)/\(FlowDictionaryError.phraseLimit)" : nil
    }

    var correctCounter: String? {
        let count = trimmedCorrect.count
        let limit = FlowDictionaryError.replacementLimit
        return count >= limit - 200 ? "\(count)/\(limit)" : nil
    }

    // MARK: Submit

    func submit() {
        guard isPresented, canSubmit else { return }
        let store = FlowDictionaryStore.shared
        let replacement = isReplacement ? trimmedCorrect : nil
        do {
            if let entry = editingEntry {
                try store.update(entry, phrase: trimmedWord, replacement: replacement)
                isPresented = false
                FlowToastCenter.shared.show("Saved", style: .success)
            } else {
                try store.add(phrase: trimmedWord, replacement: replacement)
                isPresented = false
                FlowToastCenter.shared.show("Added to your dictionary", style: .success)
            }
        } catch {
            submitError = error.localizedDescription
        }
    }
}

/// "Add to vocabulary" / "Edit word" dialog, built on FlowDialog. Present it with
/// `.flowDialog(isPresented: $model.isPresented, primaryAction: model.submit)`.
struct FlowDictionaryAddDialog: View {
    @ObservedObject var model: FlowDictionaryAddModel

    private let contentWidth: CGFloat = 432   // 480 minimum dialog width minus 2 x 24 padding

    var body: some View {
        FlowDialog(title: model.isEditing ? "Edit word" : "Add to vocabulary") {
            VStack(alignment: .leading, spacing: 24) {
                misspellingSwitch
                fields
                if let error = model.inlineError {
                    Text(error)
                        .font(FlowFont.sans(12))
                        .foregroundStyle(FlowColor.destructive)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, -16)
                }
            }
            .frame(width: contentWidth, alignment: .leading)
            .animation(FlowMotion.standard, value: model.isReplacement)
        } actions: {
            Button("Cancel") { model.dismiss() }
                .buttonStyle(FlowButtonStyle(variant: .secondary))
                .keyboardShortcut(.cancelAction)
            Button(model.isEditing ? "Save" : "Add word") { model.submit() }
                .buttonStyle(FlowButtonStyle(variant: .primary))
                .disabled(!model.canSubmit)
        }
    }

    private var misspellingSwitch: some View {
        HStack(spacing: 6) {
            Text("Correct a misspelling")
                .flowText(.sm)
                .foregroundStyle(FlowColor.neutral600)
            FlowIcon(.info, size: 14, color: FlowColor.foregroundTertiary)
                .flowHint("Replace a word Free Flow keeps getting wrong with the right spelling")
            Spacer(minLength: 12)
            Toggle("Correct a misspelling", isOn: $model.isReplacement)
                .labelsHidden()
                .toggleStyle(FlowSwitchStyle())
        }
    }

    @ViewBuilder
    private var fields: some View {
        if model.isReplacement {
            HStack(alignment: .top, spacing: 12) {
                field("Misspelling", text: $model.word, counter: model.wordCounter)
                Text("→")
                    .font(FlowFont.sans(16, weight: 600))
                    .lineSpacing(24 - 16 * 1.2)
                    .foregroundStyle(FlowColor.foregroundTertiary)
                    .frame(height: 40)
                field("Correct spelling", text: $model.correctSpelling, counter: model.correctCounter)
            }
        } else {
            field("Add a new word", text: $model.word, counter: model.wordCounter)
        }
    }

    private func field(_ placeholder: String, text: Binding<String>, counter: String?) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            FlowTextField(placeholder, text: text, width: nil, onSubmit: { model.submit() })
            if let counter {
                Text(counter)
                    .font(FlowFont.sans(12))
                    .foregroundStyle(FlowColor.foregroundTertiary)
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity)
    }
}
