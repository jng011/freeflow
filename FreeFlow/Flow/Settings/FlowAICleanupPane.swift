import SwiftUI

enum FlowCleanupLevel: String, CaseIterable, Identifiable {
    case none, light, medium, high
    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .light: return "Light"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    var detail: String {
        switch self {
        case .none: return "Transcribes exactly what you said, including mistakes"
        case .light: return "Cleans up filler words and grammar"
        case .medium: return "Edits for clarity and conciseness"
        case .high: return "Rewrites for brevity and polish"
        }
    }
}

/// Turns AI cleanup on or off the same way the Engine page did: through the default mode,
/// pointed at OpenRouter and the chosen model. ParleCleanupAutoEnabled mirrors the switch.
@MainActor
enum FlowCleanupSwitch {
    static var defaultMode: ModeConfig? {
        ModeManager.shared.configurations.first(where: \.isDefault) ?? ModeManager.shared.configurations.first
    }

    static var isOn: Bool {
        defaultMode?.isAIEnhancementEnabled ?? UserDefaults.standard.bool(forKey: FlowLegacyKeys.liveCleanup)
    }

    static func set(_ on: Bool, aiService: AIService) {
        UserDefaults.standard.set(on, forKey: FlowLegacyKeys.liveCleanup)
        if var mode = defaultMode {
            mode.isAIEnhancementEnabled = on
            if on {
                if mode.selectedPrompt == nil { mode.selectedPrompt = PromptTemplates.defaultPromptId.uuidString }
                mode.selectedAIProvider = AIProvider.openRouter.rawValue
                mode.selectedAIModel = aiService.selectedModel(for: .openRouter)
            }
            ModeManager.shared.updateConfiguration(mode)
        }
        NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
    }

    /// Points the global selection and every mode at OpenRouter and `model`.
    static func apply(model: String, aiService: AIService) {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return }
        aiService.selectedProvider = .openRouter
        aiService.selectModel(model, for: .openRouter)
        for var config in ModeManager.shared.configurations
        where config.selectedAIProvider != AIProvider.openRouter.rawValue || config.selectedAIModel != model {
            config.selectedAIProvider = AIProvider.openRouter.rawValue
            config.selectedAIModel = model
            ModeManager.shared.updateConfiguration(config)
        }
        NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
    }
}

struct FlowAICleanupPane: View {
    @EnvironmentObject private var presenter: FlowSettingsPresenter
    @EnvironmentObject private var aiService: AIService

    @AppStorage(FlowKeys.autoCleanupLevel) private var levelRaw = FlowCleanupLevel.light.rawValue
    @AppStorage(FlowKeys.cleanupCustomRules) private var customRules = ""
    @AppStorage(FlowKeys.pressEnterCommand) private var pressEnter = false
    @AppStorage(FlowAskSiriCommand.enabledKey) private var askSiri = false
    @AppStorage(FlowPromptMode.enabledKey) private var promptMode = true
    @AppStorage(FlowLegacyKeys.skipShortEnhancement) private var skipShort = true
    @AppStorage(FlowLegacyKeys.shortEnhancementWordThreshold) private var shortThreshold = 8
    @AppStorage(EnhancementRequestSettings.timeoutKey) private var timeoutSeconds = EnhancementRequestSettings
        .defaultTimeoutSeconds
    @AppStorage(EnhancementRequestSettings.retryOnTimeoutKey) private var retryOnTimeout = EnhancementRequestSettings
        .defaultRetryOnTimeout

    @State private var cleanupOn = false
    @State private var styleRevision = 0
    @State private var apiKeyInput = ""
    @State private var keyStatus: KeyStatus = .unknown
    @State private var modelID = ""

    enum KeyStatus: Equatable {
        case unknown, verifying, valid, invalid(String)
    }

    private static let rulesLimit = 1000

    private var level: FlowCleanupLevel { FlowCleanupLevel(rawValue: levelRaw) ?? .light }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            cleanupCard
            styleCard
            rulesCard
            modelCard
            voiceCommandsCard
            advanced
        }
        .onAppear(perform: load)
    }

    // MARK: Cleanup

    private var cleanupCard: some View {
        FlowSettingsSection(title: "Cleanup") {
            FlowSettingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Cleanup level")
                        .flowText(.smEmph)
                        .foregroundStyle(FlowColor.foreground)
                    HStack(spacing: 8) {
                        ForEach(FlowCleanupLevel.allCases) { item in
                            FlowSettingsChip(title: item.title, isSelected: level == item) {
                                setLevel(item)
                            }
                        }
                    }
                    Text(level.detail)
                        .flowText(.sm)
                        .foregroundStyle(FlowColor.foregroundTertiary)
                }
                .padding(.vertical, 8)

                if level != .none {
                    FlowSettingsRow(
                        title: "Clean up while dictating",
                        description: "Free Flow tidies your words with AI before pasting."
                    ) {
                        FlowSettingsSwitch(
                            isOn: Binding(
                                get: { cleanupOn },
                                set: { newValue in
                                    cleanupOn = newValue
                                    FlowCleanupSwitch.set(newValue, aiService: aiService)
                                }
                            ))
                            .disabled(apiKeyInput.isEmpty && !cleanupOn)
                    }
                }
            }
        }
    }

    private func setLevel(_ newLevel: FlowCleanupLevel) {
        let oldLevel = level
        guard newLevel != oldLevel else { return }
        let defaults = UserDefaults.standard
        if newLevel == .none {
            defaults.set(FlowCleanupSwitch.isOn, forKey: FlowSettingsPrivateKeys.previousLiveCleanup)
            FlowCleanupSwitch.set(false, aiService: aiService)
            cleanupOn = false
        } else if oldLevel == .none {
            let previous =
                defaults.object(forKey: FlowSettingsPrivateKeys.previousLiveCleanup) as? Bool ?? true
            FlowCleanupSwitch.set(previous, aiService: aiService)
            cleanupOn = previous
        }
        levelRaw = newLevel.rawValue
        NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
    }

    // MARK: Style

    private var styleCard: some View {
        FlowSettingsSection(title: "Style", subtitle: "Style formatting only applies in English.") {
            FlowSettingsCard {
                styleRow("Personal messages", category: .personal)
                styleRow("Work messages", category: .work)
                styleRow("Email", category: .email)
                styleRow("Other", category: .other)
            }
            .id(styleRevision)
        }
    }

    private func styleRow(_ title: String, category: FlowStyleCategory) -> some View {
        let presets: [FlowStylePreset] =
            category == .personal ? [.formal, .casual, .veryCasual] : [.formal, .casual, .excited]
        return FlowSettingsRow(title: title, description: styleSubtitle(FlowDefaults.stylePreset(for: category))) {
            FlowSettingsDropdown(
                selection: Binding(
                    get: { FlowDefaults.stylePreset(for: category) },
                    set: { newValue in
                        FlowDefaults.setStylePreset(newValue, for: category)
                        styleRevision += 1
                    }
                ),
                options: presets.map {
                    FlowSettingsOption(value: $0, title: styleTitle($0), subtitle: styleSubtitle($0))
                }
            )
        }
    }

    private func styleTitle(_ preset: FlowStylePreset) -> String {
        switch preset {
        case .formal: return "Formal"
        case .casual: return "Casual"
        case .veryCasual: return "very casual"
        case .excited: return "Excited"
        }
    }

    private func styleSubtitle(_ preset: FlowStylePreset) -> String {
        switch preset {
        case .formal: return "Caps + Punctuation"
        case .casual: return "Caps + Less punctuation"
        case .veryCasual: return "No Caps + Less punctuation"
        case .excited: return "More exclamations"
        }
    }

    // MARK: Rules

    private var rulesCard: some View {
        FlowSettingsSection(title: "Your rules") {
            FlowSettingsCard {
                VStack(alignment: .trailing, spacing: 8) {
                    FlowSettingsTextArea(
                        placeholder: "Example: Always write numbers as digits. Spell my company as ACME.",
                        text: Binding(
                            get: { customRules },
                            set: { newValue in
                                customRules = String(newValue.prefix(Self.rulesLimit))
                                NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
                            }
                        ),
                        height: 120
                    )
                    Text("\(customRules.count)/\(Self.rulesLimit)")
                        .flowText(.xs)
                        .monospacedDigit()
                        .foregroundStyle(FlowColor.foregroundTertiary)
                }
                .padding(.vertical, 8)
            }
        }
    }

    // MARK: Model

    private var modelOptions: [FlowSettingsOption<String>] {
        var options = AIProvider.openRouter.recommendedModels.map {
            FlowSettingsOption(value: $0.id, title: $0.name, subtitle: $0.note)
        }
        let known = Set(options.map(\.value))
        let catalog = aiService.availableModels(for: .openRouter).filter { !known.contains($0) }
        options += catalog.map { FlowSettingsOption(value: $0, title: ParleFreeModels.readableName(for: $0), subtitle: $0) }
        if !modelID.isEmpty, !options.contains(where: { $0.value == modelID }) {
            options.insert(
                FlowSettingsOption(value: modelID, title: ParleFreeModels.readableName(for: modelID), subtitle: modelID),
                at: 0
            )
        }
        return options
    }

    private var modelCard: some View {
        FlowSettingsSection(title: "Model") {
            FlowSettingsCard {
                FlowSettingsRow(title: "Provider") {
                    Text("OpenRouter")
                        .flowText(.sm)
                        .foregroundStyle(FlowColor.foregroundTertiary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }

                FlowSettingsRow(title: "API key", controlWidth: 320) {
                    keyStatusText
                } control: {
                    HStack(spacing: 8) {
                        FlowSettingsTextField(placeholder: "sk-or-...", text: $apiKeyInput, isSecure: true) {
                            saveKey()
                        }
                        Button(keyStatus == .verifying ? "Checking..." : "Save") { saveKey() }
                            .flowSettingsButton(.secondary)
                            .disabled(apiKeyInput.isEmpty || keyStatus == .verifying)
                    }
                }

                FlowSettingsRow(title: "Model", description: "Faster models paste sooner.", controlWidth: 220) {
                    FlowSettingsDropdown(
                        selection: Binding(
                            get: { modelID },
                            set: { newValue in
                                modelID = newValue
                                FlowCleanupSwitch.apply(model: newValue, aiService: aiService)
                            }
                        ),
                        options: modelOptions,
                        width: 220
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var keyStatusText: some View {
        switch keyStatus {
        case .unknown:
            Text("Your OpenRouter key stays in this Mac's keychain.")
                .flowText(.sm)
                .foregroundStyle(FlowColor.foregroundTertiary)
        case .verifying:
            Text("Checking key...")
                .flowText(.sm)
                .foregroundStyle(FlowColor.foregroundTertiary)
        case .valid:
            Text("Key works")
                .flowText(.sm)
                .foregroundStyle(FlowColor.success)
        case .invalid(let message):
            Text(message)
                .flowText(.sm)
                .foregroundStyle(FlowColor.destructive)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Voice commands

    private var voiceCommandsCard: some View {
        FlowSettingsSection(title: "Voice commands") {
            FlowSettingsCard {
                FlowSettingsRow(
                    title: "Press enter command",
                    description: "Say 'press enter' at the end of a dictation to send it"
                ) {
                    FlowSettingsSwitch(
                        isOn: Binding(
                            get: { pressEnter },
                            set: { newValue in
                                pressEnter = newValue
                                NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
                            }
                        ))
                }

                FlowSettingsRow(
                    title: "Prompt mode",
                    description: "Hold Ctrl with fn to turn what you say into a structured prompt for an AI"
                ) {
                    FlowSettingsSwitch(
                        isOn: Binding(
                            get: { promptMode },
                            set: { newValue in
                                promptMode = newValue
                                NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
                            }
                        ))
                }

                FlowSettingsRow(
                    title: "Ask Siri command",
                    description: "Start with 'ask Siri' to send the rest to Spotlight and press Return"
                ) {
                    FlowSettingsSwitch(
                        isOn: Binding(
                            get: { askSiri },
                            set: { newValue in
                                askSiri = newValue
                                NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
                            }
                        ))
                }
            }
        }
    }

    // MARK: Advanced

    private var advanced: some View {
        VStack(alignment: .leading, spacing: 16) {
            FlowSettingsHeading(title: "Advanced")
            FlowSettingsCard {
                FlowSettingsRow(title: "Skip cleanup for short dictations", controlWidth: 220) {
                    if skipShort {
                        FlowSettingsStepper(
                            value: notifying($shortThreshold),
                            range: 1...20,
                            label: { $0 == 1 ? "Up to 1 word" : "Up to \($0) words" }
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } control: {
                    FlowSettingsSwitch(isOn: notifying($skipShort))
                }

                FlowSettingsRow(title: "Request timeout", description: "How long to wait for the AI model", controlWidth: 220) {
                    FlowSettingsStepper(
                        value: notifying($timeoutSeconds),
                        range: 5...60,
                        label: { "\($0) s" }
                    )
                }

                FlowSettingsRow(title: "Retry on timeout") {
                    FlowSettingsSwitch(isOn: notifying($retryOnTimeout))
                }

                FlowSettingsRow(title: "Advanced: Modes", description: "Per-app prompts and models") {
                    FlowSettingsActionButton(title: "Open") { presenter.sheet = .modes }
                }
            }
        }
    }

    // MARK: Actions

    private func notifying<T>(_ binding: Binding<T>) -> Binding<T> {
        Binding(
            get: { binding.wrappedValue },
            set: { newValue in
                binding.wrappedValue = newValue
                NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
            }
        )
    }

    private func load() {
        cleanupOn = level != .none && FlowCleanupSwitch.isOn
        shortThreshold = min(max(shortThreshold, 1), 20)
        timeoutSeconds = min(max(timeoutSeconds, 5), 60)
        let selected = aiService.selectedModel(for: .openRouter)
        modelID = selected.isEmpty ? (AIProvider.openRouter.recommendedModels.first?.id ?? "") : selected
        apiKeyInput = APIKeyManager.shared.getAPIKey(forProvider: AIProvider.openRouter.rawValue) ?? ""
        guard !apiKeyInput.isEmpty else {
            keyStatus = .unknown
            return
        }
        keyStatus = .verifying
        let key = apiKeyInput
        let model = modelID
        Task {
            let result = await aiService.verifyAPIKey(key, for: .openRouter, model: model.isEmpty ? nil : model)
            keyStatus = result.isValid ? .valid : .invalid(result.errorMessage ?? "That key didn't work.")
        }
    }

    private func saveKey() {
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        let model = modelID
        keyStatus = .verifying
        Task {
            let result = await aiService.verifyAPIKey(key, for: .openRouter, model: model)
            if result.isValid {
                _ = APIKeyManager.shared.saveAPIKey(key, forProvider: AIProvider.openRouter.rawValue)
                NotificationCenter.default.post(name: .aiProviderKeyChanged, object: nil)
                keyStatus = .valid
                FlowCleanupSwitch.apply(model: model, aiService: aiService)
                if level != .none && !FlowCleanupSwitch.isOn {
                    FlowCleanupSwitch.set(true, aiService: aiService)
                    cleanupOn = true
                }
                FlowToastCenter.shared.show("API key saved")
            } else {
                keyStatus = .invalid(result.errorMessage ?? "That key didn't work.")
            }
        }
    }
}
