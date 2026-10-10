import AppIntents
import AppKit
import FluidAudio
import OSLog
import SwiftData
import SwiftUI

@main
struct FreeFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    let container: ModelContainer

    @StateObject private var engine: FreeFlowEngine
    // Retain managers without subscribing the entire scene to download progress.
    @State private var whisperModelManager: WhisperModelManager
    @State private var fluidAudioModelManager: FluidAudioModelManager
    @StateObject private var transcriptionModelManager: TranscriptionModelManager
    @StateObject private var recorderUIManager: RecorderUIManager
    @StateObject private var recordingShortcutManager: RecordingShortcutManager
    @StateObject private var updaterViewModel: UpdaterViewModel
    @StateObject private var menuBarManager: MenuBarManager
    @StateObject private var mainWindowNavigation = MainWindowNavigation.shared
    @StateObject private var aiService = AIService()
    @StateObject private var enhancementService: AIEnhancementService
    @StateObject private var activeWindowService = ActiveWindowService.shared
    @AppStorage(OnboardingSettings.completedV2Key) private var hasCompletedOnboardingV2 = false
    @State private var showMenuBarIcon = true
    @State private var didShowLaunchReminders = false

    // Audio cleanup manager for automatic deletion of old audio files
    private let audioCleanupManager = AudioCleanupManager.shared

    // Transcription auto-cleanup service for zero data retention
    private let transcriptionAutoCleanupService = TranscriptionAutoCleanupService.shared

    // Model prewarm service for optimizing model on wake from sleep
    @StateObject private var prewarmService: ModelPrewarmService

    init() {
        _ = LogExporter.shared

        // Disable HTTP response caching — prevents API responses from being stored in Cache.db
        URLCache.shared = URLCache(memoryCapacity: 0, diskCapacity: 0)

        AppDefaults.registerDefaults()
        FlowFonts.registerAll()
        FlowDefaults.register()
        AppLanguagePreference.applyStored()
        AppAppearancePreference.applyStored()

        let logger = Logger(subsystem: "com.jaydenghiyam.parle", category: "Initialization")
        // Keep existing model order stable; append new models after synced entities.
        let schema = Schema([
            Transcription.self,
            VocabularyWord.self,
            WordReplacement.self,
            SessionMetric.self,
        ])
        let resolvedContainer: ModelContainer

        // Attempt 1: Try persistent storage
        do {
            resolvedContainer = try Self.createPersistentContainer(schema: schema, logger: logger)
        } catch let persistentError {
            // Attempt 2: Try in-memory storage
            do {
                resolvedContainer = try Self.createInMemoryContainer(schema: schema, logger: logger)
                logger.warning("Using in-memory storage as fallback. Data will not persist between sessions.")

                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = String(localized: "Storage Warning")
                    alert.informativeText = String(
                        localized:
                            "Free Flow couldn't access its storage location. Your transcriptions will not be saved between sessions."
                    )
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: String(localized: "OK"))
                    alert.runModal()
                }
            } catch let memoryError {
                let persistentDetail = Self.fullErrorDescription(persistentError)
                let memoryDetail = Self.fullErrorDescription(memoryError)
                logger.critical(
                    "❌ All ModelContainer init attempts failed.\nPersistent:\n\(persistentDetail, privacy: .public)\nIn-memory:\n\(memoryDetail, privacy: .public)"
                )
                fatalError(
                    "Free Flow failed to initialize storage.\nPersistent:\n\(persistentDetail)\nIn-memory:\n\(memoryDetail)"
                )
            }
        }

        container = resolvedContainer
        DictionaryService.cleanUpDictionaryContent(context: resolvedContainer.mainContext, source: "launch")

        // Initialize services with proper sharing of instances
        let aiService = AIService()
        _aiService = StateObject(wrappedValue: aiService)
        Task { @MainActor in
            await aiService.fetchOpenRouterModelsIfNeededForMigration()
        }

        let updaterViewModel = UpdaterViewModel()
        _updaterViewModel = StateObject(wrappedValue: updaterViewModel)

        let enhancementService = AIEnhancementService(aiService: aiService, modelContext: resolvedContainer.mainContext)
        _enhancementService = StateObject(wrappedValue: enhancementService)
        let autoLearnReviewer = AutoLearnAIReviewer(enhancementService: enhancementService)
        Task {
            await AutoLearnService.shared.configure(
                modelContainer: resolvedContainer,
                reviewer: autoLearnReviewer
            )
        }

        // 1. Create modelsDirectory URL
        let appSupportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.jaydenghiyam.FreeFlow")
        let modelsDirectory = appSupportDirectory.appendingPathComponent("WhisperModels")

        // 2. Create model managers
        let whisperModelManager = WhisperModelManager(modelsDirectory: modelsDirectory)
        let fluidAudioModelManager = FluidAudioModelManager()
        let transcriptionModelManager = TranscriptionModelManager(
            whisperModelManager: whisperModelManager,
            fluidAudioModelManager: fluidAudioModelManager
        )

        // 3. Create UI manager
        let recorderUIManager = RecorderUIManager()

        // 4. Create engine
        let engine = FreeFlowEngine(
            modelContext: resolvedContainer.mainContext,
            whisperModelManager: whisperModelManager,
            transcriptionModelManager: transcriptionModelManager,
            enhancementService: enhancementService
        )

        // 5. Configure circular deps
        recorderUIManager.configure(engine: engine, recorder: engine.recorder)
        engine.recorderUIManager = recorderUIManager

        // 6. Initialize model state
        // Migration and refreshAllAvailableModels must run before loadCurrentTranscriptionModel so renamed keys are remapped and imported models are present when restoring the saved selection.
        StreamingKeysMigration.run()
        whisperModelManager.createModelsDirectoryIfNeeded()
        whisperModelManager.loadAvailableModels()
        transcriptionModelManager.refreshAllAvailableModels()
        transcriptionModelManager.loadCurrentTranscriptionModel()

        _whisperModelManager = State(initialValue: whisperModelManager)
        _fluidAudioModelManager = State(initialValue: fluidAudioModelManager)
        _transcriptionModelManager = StateObject(wrappedValue: transcriptionModelManager)
        _recorderUIManager = StateObject(wrappedValue: recorderUIManager)
        _engine = StateObject(wrappedValue: engine)

        // 7. Create other services that depend on engine
        let recordingShortcutManager = RecordingShortcutManager(engine: engine, recorderUIManager: recorderUIManager)
        _recordingShortcutManager = StateObject(wrappedValue: recordingShortcutManager)
        FlowSettingsAttention.shortcutManager = recordingShortcutManager

        // Flow services (order matters: stats and dictionary before Files and the MCP bridge).
        FlowModeSeeder.ensureDefaultMode()
        FlowModeSeeder.migrateSlowCleanupModel()
        FlowScreenContextPermission.requestIfNeeded()
        FlowStatsStore.shared.start(modelContainer: resolvedContainer)
        FlowDictionaryStore.shared.configure(modelContext: resolvedContainer.mainContext)
        FlowFilesStore.shared.configure(engine: engine, modelContext: resolvedContainer.mainContext)
        FlowMCPBridge.shared.start()

        let menuBarManager = MenuBarManager()
        _menuBarManager = StateObject(wrappedValue: menuBarManager)
        menuBarManager.configure(engine: engine)

        let activeWindowService = ActiveWindowService.shared
        _activeWindowService = StateObject(wrappedValue: activeWindowService)

        let prewarmService = ModelPrewarmService(
            transcriptionModelManager: transcriptionModelManager,
            whisperModelManager: whisperModelManager,
            modelContext: resolvedContainer.mainContext
        )
        _prewarmService = StateObject(wrappedValue: prewarmService)

        appDelegate.menuBarManager = menuBarManager
        appDelegate.engine = engine

        // Ensure no lingering recording state from previous runs
        Task {
            await recorderUIManager.resetOnLaunch()
        }

        // A dictation left pending by a quit or crash becomes retryable from History.
        Task { @MainActor [weak engine] in
            try? await Task.sleep(for: .seconds(2))
            guard let recovered = engine?.recoverInterruptedDictations() else { return }
            let id = recovered.id
            FlowBarController.shared.showToast(
                FlowBarToast(
                    style: .standard,
                    title: "Recovered your last dictation",
                    body: "Free Flow closed before it finished. Retry it from History.",
                    actionTitle: "Retry",
                    action: { Task { await FlowDictationActions.retry(transcriptionID: id) } },
                    duration: 8
                )
            )
        }

        AppShortcuts.updateAppShortcutParameters()

        let statsMigrationTask = SessionMetricMigrationService.shared.runStatsMigrationIfNeeded(
            modelContainer: resolvedContainer)
        let mainContext = resolvedContainer.mainContext
        Task { @MainActor in
            await statsMigrationTask?.value
            TranscriptionAutoCleanupService.shared.startMonitoring(modelContext: mainContext)

            let tokenBackfillTask = SessionMetricMigrationService.shared.runEnhancementTokenBackfillIfNeeded(
                modelContainer: resolvedContainer)
            await tokenBackfillTask?.value
        }
    }

    // MARK: - Container Creation Helpers

    private static func fullErrorDescription(_ error: Error, depth: Int = 0) -> String {
        let ns = error as NSError
        let indent = String(repeating: "  ", count: depth)
        var lines: [String] = []
        lines.append("\(indent)[\(ns.domain) \(ns.code)] \(ns.localizedDescription)")
        for (key, value) in ns.userInfo {
            let keyStr = "\(key)"
            if keyStr == NSUnderlyingErrorKey || keyStr == "NSDetailedErrors" { continue }
            lines.append("\(indent)  \(keyStr): \(value)")
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error {
            lines.append("\(indent)  Underlying:")
            lines.append(fullErrorDescription(underlying, depth: depth + 2))
        }
        if let details = ns.userInfo["NSDetailedErrors"] as? [Error] {
            lines.append("\(indent)  DetailedErrors (\(details.count)):")
            for (i, detail) in details.enumerated() {
                lines.append("\(indent)    [\(i)]:")
                lines.append(fullErrorDescription(detail, depth: depth + 3))
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func createPersistentContainer(schema: Schema, logger: Logger) throws -> ModelContainer {
        let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.jaydenghiyam.FreeFlow", isDirectory: true)

        try? FileManager.default.createDirectory(at: appSupportURL, withIntermediateDirectories: true)

        let defaultStoreURL = appSupportURL.appendingPathComponent("default.store")
        let dictionaryStoreURL = appSupportURL.appendingPathComponent("dictionary.store")
        let statsStoreURL = appSupportURL.appendingPathComponent("stats.store")

        let transcriptSchema = Schema([Transcription.self])
        let transcriptConfig = ModelConfiguration(
            "default",
            schema: transcriptSchema,
            url: defaultStoreURL,
            cloudKitDatabase: .none
        )

        let dictionarySchema = Schema([VocabularyWord.self, WordReplacement.self])
        // Dev shares the local stores but must never connect to CloudKit.
        #if DEBUG || LOCAL_BUILD
            let dictionaryCloudKit: ModelConfiguration.CloudKitDatabase = .none
        #else
            let dictionaryCloudKit: ModelConfiguration.CloudKitDatabase = .private(
                "iCloud.com.jaydenghiyam.FreeFlow")
        #endif
        let dictionaryConfig = ModelConfiguration(
            "dictionary",
            schema: dictionarySchema,
            url: dictionaryStoreURL,
            cloudKitDatabase: dictionaryCloudKit
        )

        let statsSchema = Schema([SessionMetric.self])
        let statsConfig = ModelConfiguration(
            "stats",
            schema: statsSchema,
            url: statsStoreURL,
            cloudKitDatabase: .none
        )

        do {
            return try ModelContainer(for: schema, configurations: transcriptConfig, dictionaryConfig, statsConfig)
        } catch {
            logger.error(
                "❌ Failed to create persistent ModelContainer:\n\(Self.fullErrorDescription(error), privacy: .public)")
            throw error
        }
    }

    private static func createInMemoryContainer(schema: Schema, logger: Logger) throws -> ModelContainer {
        let transcriptSchema = Schema([Transcription.self])
        let transcriptConfig = ModelConfiguration("default", schema: transcriptSchema, isStoredInMemoryOnly: true)

        let dictionarySchema = Schema([VocabularyWord.self, WordReplacement.self])
        let dictionaryConfig = ModelConfiguration("dictionary", schema: dictionarySchema, isStoredInMemoryOnly: true)

        let statsSchema = Schema([SessionMetric.self])
        let statsConfig = ModelConfiguration("stats", schema: statsSchema, isStoredInMemoryOnly: true)

        do {
            return try ModelContainer(for: schema, configurations: transcriptConfig, dictionaryConfig, statsConfig)
        } catch {
            logger.error(
                "❌ Failed to create in-memory ModelContainer:\n\(Self.fullErrorDescription(error), privacy: .public)")
            throw error
        }
    }

    var body: some Scene {
        Window("Free Flow", id: AppWindowID.main) {
            Group {
                if hasCompletedOnboardingV2 {
                    FlowRootView()
                        .onAppear {
                            showLaunchRemindersIfNeeded()
                            ParleEngine.shared.startMonitoring()
                            ParleEngine.prepareOnDeviceModelIfNeeded(whisperModelManager: whisperModelManager)
                            // ParleDictionarySeed is not run: it would add "Parle" and a parlay -> Parle rule.
                            FlowDictionarySeed.runIfNeeded(context: container.mainContext)

                            // Run due audio-only cleanup and schedule future checks when transcript cleanup is not managing retention.
                            if !UserDefaults.standard.bool(forKey: CleanupSettingsKeys.isTranscriptionCleanupEnabled)
                                && UserDefaults.standard.bool(forKey: CleanupSettingsKeys.isAudioCleanupEnabled)
                            {
                                Task {
                                    await audioCleanupManager.runAutomaticCleanupIfNeeded(
                                        modelContext: container.mainContext)
                                }
                                audioCleanupManager.startAutomaticCleanup(modelContext: container.mainContext)
                            }

                            // Process any pending open-file request now that the main window is ready.
                            if let pendingURL = appDelegate.pendingOpenFileURL {
                                NotificationCenter.default.post(
                                    name: .navigateToDestination, object: nil,
                                    userInfo: ["destination": "Transcribe Audio"])
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    NotificationCenter.default.post(
                                        name: .openFileForTranscription, object: nil, userInfo: ["url": pendingURL])
                                }
                                appDelegate.pendingOpenFileURL = nil
                            }
                        }
                        .onDisappear {
                            whisperModelManager.unloadModel()

                            // Stop the automatic audio cleanup process
                            audioCleanupManager.stopAutomaticCleanup()
                        }
                } else {
                    FlowOnboardingView()
                        .onAppear {
                            ParleEngine.prepareOnDeviceModelIfNeeded(whisperModelManager: whisperModelManager)
                        }
                }
            }
            .environmentObject(engine)
            .environmentObject(whisperModelManager)
            .environmentObject(fluidAudioModelManager)
            .environmentObject(transcriptionModelManager)
            .environmentObject(recorderUIManager)
            .environmentObject(recordingShortcutManager)
            .environmentObject(updaterViewModel)
            .environmentObject(menuBarManager)
            .environmentObject(mainWindowNavigation)
            .environmentObject(aiService)
            .environmentObject(enhancementService)
            .modelContainer(container)
            .frame(minWidth: AppWindowLayout.minimumWidth, minHeight: AppWindowLayout.minimumHeight)
            .background(
                WindowAccessor { window in
                    WindowManager.shared.configureWindow(window)
                }
            )
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: AppWindowLayout.width, height: AppWindowLayout.height)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}

            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updaterViewModel: updaterViewModel)
            }

            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    FlowNavigator.shared.presentSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            FlowNavigationCommands()
        }

        MenuBarExtra(isInserted: $showMenuBarIcon) {
            MenuBarView()
                .environmentObject(engine)
                .environmentObject(whisperModelManager)
                .environmentObject(fluidAudioModelManager)
                .environmentObject(transcriptionModelManager)
                .environmentObject(recorderUIManager)
                .environmentObject(recordingShortcutManager)
                .environmentObject(menuBarManager)
                .environmentObject(mainWindowNavigation)
                .environmentObject(updaterViewModel)
                .environmentObject(aiService)
                .environmentObject(enhancementService)
                .modelContainer(container)
        } label: {
            let image: NSImage = {
                let ratio = $0.size.height / max($0.size.width, 1)
                $0.size.height = 18
                $0.size.width = 18 / max(ratio, 0.01)
                return $0
            }(
                NSImage(named: "menuBarIcon")
                    ?? NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)!
            )

            Image(nsImage: image)
                .help("Free Flow")
                .background(MainWindowRequestBridge(menuBarManager: menuBarManager))
        }
        .menuBarExtraStyle(.menu)

        #if DEBUG
            WindowGroup("Debug") {
                Button("Toggle Menu Bar Only") {
                    menuBarManager.isMenuBarOnly.toggle()
                }
            }
        #endif
    }

    /// Only one notification fits on screen, so show at most one launch reminder.
    private func showLaunchRemindersIfNeeded() {
        guard !didShowLaunchReminders else { return }
        didShowLaunchReminders = true

        if !AXIsProcessTrusted() {
            NotificationManager.shared.showNotification(
                title: String(localized: "Accessibility permission is not provided"),
                type: .warning,
                duration: 7.0,
                actionButton: (String(localized: "Open Settings"), Self.openAccessibilitySettings)
            )
            return
        }

        if !ModeManager.shared.hasEnabledConfiguration {
            NotificationManager.shared.showNotification(
                title: String(localized: "No mode configured"),
                type: .warning,
                duration: 7.0,
                actionButton: (String(localized: "Manage Modes"), ModeSetupNavigator.openModesSettings)
            )
        }
    }

    private static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Go menu: Cmd+1...4 pick a destination, Cmd+[ and Cmd+] walk the destination history.
private struct FlowNavigationCommands: Commands {
    var body: some Commands {
        CommandMenu("Go") {
            ForEach(FlowDestination.allCases) { destination in
                Button(destination.title) {
                    FlowNavigator.shared.open(destination)
                }
                .keyboardShortcut(destination.shortcutKey, modifiers: .command)
            }

            Divider()

            Button("Back") {
                FlowNavigator.shared.goBack()
            }
            .keyboardShortcut("[", modifiers: .command)

            Button("Forward") {
                FlowNavigator.shared.goForward()
            }
            .keyboardShortcut("]", modifiers: .command)

            Divider()

            Button("Toggle Sidebar") {
                withAnimation(FlowMotion.standard) {
                    FlowNavigator.shared.toggleSidebar()
                }
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
        }
    }
}

private struct MainWindowRequestBridge: View {
    @Environment(\.openWindow) private var openWindow
    let menuBarManager: MenuBarManager

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onReceive(NotificationCenter.default.publisher(for: .showMainWindowRequested)) { _ in
                let existingWindow = WindowManager.shared.currentMainWindow()

                if existingWindow == nil {
                    menuBarManager.activateForPresentedWindow()
                    WindowManager.shared.prepareForUserRequestedMainWindow()
                    openWindow(id: AppWindowID.main)
                } else {
                    menuBarManager.activateForPresentedWindow()
                    openWindow(id: AppWindowID.main)
                    WindowManager.shared.showMainWindow()
                }
            }
    }
}

struct WindowAccessor: NSViewRepresentable {
    let callback: (NSWindow) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        notifyWindowIfNeeded(for: view, context: context)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        notifyWindowIfNeeded(for: nsView, context: context)
    }

    private func notifyWindowIfNeeded(for view: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = view.window,
                context.coordinator.window !== window
            {
                context.coordinator.window = window
                callback(window)
            }
        }
    }

    final class Coordinator {
        weak var window: NSWindow?
    }
}
