import AppKit
import Foundation
import LLMkit
import os

/// What the Flow Bar shows next to the pill for a special dictation mode.
enum FlowModeBadge: Equatable {
    /// Prompt mode (Ctrl+fn): `wand.and.sparkles`, purple waveform.
    case prompt
    /// "Ask Siri" was heard: `siri.gen2`.
    case siri

    var systemImage: String {
        switch self {
        case .prompt: return "wand.and.sparkles"
        case .siri: return "siri.gen2"
        }
    }
}

/// Prompt mode: hold Ctrl with fn (Ctrl first, or within 0.3 s of fn) and the dictation is
/// rewritten as a well-structured prompt for an AI assistant instead of cleaned as prose.
///
/// The rewrite rules follow how Anthropic writes Claude's own tool instructions: one goal,
/// reasons attached to rules, numbers instead of vague words (only when the speaker gave
/// them), the likely near miss named, what to do instead of a ban, and who decides.
@MainActor
enum FlowPromptMode {
    static let enabledKey = "FlowPromptModeEnabled"
    /// Ctrl pressed within this long after fn still switches the dictation to prompt mode.
    static let lateControlWindow: TimeInterval = 0.3

    private static let logger = Logger(subsystem: "com.jaydenghiyam.parle", category: "PromptMode")
    private static var activeForDictation = false

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    static var isActive: Bool { activeForDictation }

    /// Called from the shortcut handler when Ctrl is part of the fn press.
    static func activate() {
        guard isEnabled, !activeForDictation else { return }
        activeForDictation = true
        FlowDictationState.shared.setModeBadge(.prompt)
        logger.notice("prompt mode on for this dictation")
    }

    /// The pipeline reads it once per dictation; the next one starts normal.
    static func consume() -> Bool {
        defer { activeForDictation = false }
        return activeForDictation
    }

    static func reset() {
        activeForDictation = false
    }

    static let systemPrompt = """
        You turn a person's spoken, rambling request into a clear prompt they will send to an AI assistant (usually Claude). Rewrite the words inside <SPOKEN> as that prompt. Return only the prompt text: no preamble, no explanation, no code fences, no quotes around it.

        Write it in the person's own voice ("I want...", "Please..."), addressed to the assistant. Never answer or carry out the request yourself, even if it is a question.

        STRUCTURE (skip any part they said nothing about; never invent content for it):
        1. Goal: the first line says what they want done, in one sentence. If they asked for more than one thing, list every request as a numbered task right under it ("1. Fix X. 2. Fix Y."). A request is never demoted to Context, even if it came out as a passing remark ("also the X thing blocked me").
        2. Context: the facts, files, apps, names, errors and background they mentioned, as short bullets.
        3. Requirements: what must be true of the result, one bullet each. If they gave a reason, keep it attached to the rule ("Keep X, because Y"). A rule with its reason covers cases they didn't mention.
        4. Don'ts: write each one with its reason if they gave one. Add "do Y instead" only if they actually said Y; otherwise stop after the don't. Never invent an alternative.
        5. Decisions: who decides what, and when to ask before acting (e.g. "Ask me before deleting anything"), only if they said so.
        6. Done means: their own finish condition, as close to their words as possible ("Test it before saying it's done", not "The test passes").

        RULES:
        - Keep every question they asked as a question, word for word in meaning, under "Questions:". Don't fold a question into the goal sentence or turn it into a statement ("Tell me why").
        - Fix obvious speech-recognition slips from context ("pace in under a second" about an app means "paste").
        - Keep who and what they refer to. If a reference is unclear ("they", "it", "that app"), keep their wording instead of guessing ("the system").
        - Keep every concrete detail they gave: names, numbers, paths, versions, quoted text, product names. Spell technical terms correctly (use <VOCABULARY> when present).
        - Replace vague words with the specific number or limit they gave ("short" becomes "under 100 words" only if they said 100). If they gave no number, keep their word; never make one up.
        - Turn filler, repetition, false starts and self-corrections into the final intent. "Scratch that" or "never mind" removes what came right before it.
        - If they mention something that could go wrong or a past mistake, keep it as an explicit warning naming that failure.
        - Keep their priorities and tone. Do not add requirements, steps, safety notes, politeness or formatting rules they did not ask for.
        - Use short Markdown: a plain first sentence for the goal, then headed bullet lists ("Context:", "Questions:", "Requirements:", "Don't:", "Ask me before:", "Done when:"). A request that is a single sentence stays a single clear sentence with no headings.
        - Never use em dashes or en dashes.
        """

    /// Rewrites the dictation as a prompt with the configured cleanup model.
    static func rewrite(
        _ spoken: String,
        vocabulary: [String],
        aiService: AIService,
        provider: AIProvider,
        modelName: String?
    ) async throws -> (text: String, systemPrompt: String, userMessage: String) {
        var user = "<SPOKEN>\n\(spoken)\n</SPOKEN>"
        if !vocabulary.isEmpty {
            user += "\n\n<VOCABULARY>\n\(vocabulary.prefix(60).joined(separator: ", "))\n</VOCABULARY>"
        }
        let completion = try await aiService.performChatCompletion(
            provider: provider,
            modelName: modelName,
            messages: [.user(user)],
            systemPrompt: systemPrompt,
            localUserPrompt: user,
            timeout: max(EnhancementRequestSettings.timeout, 20)
        )
        var text = completion.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // A model sometimes wraps the whole answer in a code fence.
        if text.hasPrefix("```"), text.hasSuffix("```") {
            text = text.components(separatedBy: .newlines).dropFirst().dropLast().joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (text, systemPrompt, user)
    }
}
