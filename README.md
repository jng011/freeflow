# Free Flow

Voice to text for your Mac. Hold **fn**, talk, let go, and your words show up wherever you're typing.

**[Download the latest version](https://github.com/jng011/freeflow/releases/latest)**: open the `.dmg` and drag Free Flow to Applications. Requires macOS 26 on Apple Silicon. Free Flow updates itself.

## What it does

- **Hold fn to talk.** Double tap fn for hands-free, tap again to stop. The fn key is read straight from the keyboard, so fast double taps don't get missed.
- **Cleans up as you go.** Filler words, false starts and punctuation are fixed before the text is pasted. Add an AI key in Settings > AI Cleanup, or use Apple Intelligence where available.
- **"Scratch that."** Say it and the last thing you said is taken back.
- **Prompt mode.** Hold Ctrl with fn and a rambling request comes out as a clear prompt for an AI assistant.
- **Ask Siri.** Start with "Ask Siri" and your words go straight to Siri.
- **Only your voice.** Free Flow can learn your voice and leave out other people talking nearby.
- **Runs on your Mac.** Whisper, Parakeet or Apple Speech, nothing to sign up for.
- **Dictionary.** Teach it names and jargon once and it spells them your way.
- **Files.** Drop in a voice memo, meeting or video to get a clean transcript.
- **Insights.** Words per minute, streaks, and where you dictate most.

## Let AI agents see your dictations

Free Flow includes a local MCP server, so agents like Claude can read your dictation history, stats and dictionary, add words, and transcribe files through the app. It runs on your Mac; nothing is sent anywhere unless the agent sends it. Open Free Flow once, then:

```sh
claude mcp add free-flow -- python3 "$HOME/Library/Application Support/com.jaydenghiyam.FreeFlow/freeflow_mcp.py"
```

The same command is in onboarding and in Settings > Data and Privacy.

## Permissions

- **Microphone:** only while you dictate.
- **Accessibility:** to paste into the app you're using.
- **Input Monitoring:** to read the fn key directly from the keyboard.

## Building

See [BUILDING.md](BUILDING.md).

## License

GPL v3, see [LICENSE](LICENSE).

---

<sub>Portions of this app are derived, with modifications, from VoiceInk (GPL v3).</sub>
