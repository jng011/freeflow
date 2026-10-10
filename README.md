# Free Flow

Voice to text for your Mac. Hold **fn**, talk, let go, and your words show up wherever you're typing.

[![Latest release](https://img.shields.io/github/v/release/jng011/freeflow)](https://github.com/jng011/freeflow/releases/latest)
![macOS 26+](https://img.shields.io/badge/macOS-26%2B-blue)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-only-lightgrey)
[![License: GPL v3](https://img.shields.io/badge/license-GPL%20v3-green)](LICENSE)

## Features

- **Hold fn to talk.** Double tap fn for hands-free, tap again to stop. The fn key is read straight from the keyboard, so fast double taps don't get missed.
- **Cleans up as you go.** Filler words, false starts and punctuation are fixed before the text is pasted. Add an AI key in Settings > AI Cleanup, or use Apple Intelligence where available.
- **"Scratch that."** Say it and the last thing you said is taken back.
- **Prompt mode.** Hold Ctrl with fn and a rambling request comes out as a clear prompt for an AI assistant.
- **Ask Siri.** Start with "Ask Siri" and your words go straight to Siri.
- **Only your voice.** Free Flow can learn your voice and leave out other people talking nearby.
- **Runs on your Mac.** Whisper, Parakeet or Apple Speech. No account needed.
- **Dictionary.** Teach it names and jargon once and it spells them your way.
- **Files.** Drop in a voice memo, meeting or video to get a clean transcript.
- **Insights.** Words per minute, streaks, and where you dictate most.

## Requirements

- macOS 26 or later
- Apple Silicon (M1 or newer). Intel Macs aren't supported.

## Installation

### Download

1. Download **`Free-Flow-<version>.dmg`** from the [latest release](https://github.com/jng011/freeflow/releases/latest).
2. Open it and drag **Free Flow** to **Applications**.
3. Open Free Flow and follow the setup. It asks for:
   - **Microphone:** only used while you dictate.
   - **Accessibility:** to paste into the app you're using.
   - **Input Monitoring:** to read the fn key directly from the keyboard.

The app is signed and notarized by Apple, so it opens without security warnings.

### Updates

Free Flow checks for updates on its own and installs them from this repository's releases.

## Let AI agents see your dictations

Free Flow includes a local MCP server, so agents like Claude can read your dictation history, stats and dictionary, add words, and transcribe files through the app. It runs on your Mac; nothing is sent anywhere unless the agent sends it. Open Free Flow once, then:

```sh
claude mcp add free-flow -- python3 "$HOME/Library/Application Support/com.jaydenghiyam.FreeFlow/freeflow_mcp.py"
```

The same command is in onboarding and in Settings > Data and Privacy.

## Build from source

### Prerequisites

- macOS 26 on Apple Silicon
- Xcode 26 with command line tools (`xcode-select --install`)
- CMake (`brew install cmake`), to build whisper.cpp

### Steps

```sh
# 1. Clone
git clone https://github.com/jng011/freeflow.git
cd freeflow

# 2. Build whisper.cpp as an xcframework into Vendor/
git clone --depth 1 https://github.com/ggml-org/whisper.cpp.git /tmp/whisper.cpp
(cd /tmp/whisper.cpp && ./build-xcframework.sh)
mkdir -p Vendor && cp -R /tmp/whisper.cpp/build-apple/whisper.xcframework Vendor/

# 3. Open in Xcode and run the FreeFlow scheme
open FreeFlow.xcodeproj
```

In Xcode, choose your own team under **Signing & Capabilities**, then press **Run** (⌘R).

To build a signed Release copy from the command line instead, see [BUILDING.md](BUILDING.md).

## Acknowledgments

Free Flow stands on these open-source projects:

**Speech**
- [whisper.cpp](https://github.com/ggml-org/whisper.cpp): fast on-device Whisper, with the Silero voice activity model
- [FluidAudio](https://github.com/FluidInference/FluidAudio): Parakeet transcription and the speaker embeddings behind "Only your voice"

**App**
- [Sparkle](https://github.com/sparkle-project/Sparkle): automatic updates
- [MarkdownUI](https://github.com/gonzalezreal/swift-markdown-ui): rendering formatted text
- [SelectedTextKit](https://github.com/tisfeng/SelectedTextKit), with [AXSwift](https://github.com/tisfeng/AXSwift) and [KeySender](https://github.com/jordanbaird/KeySender): reading the text around your cursor
- MediaRemoteAdapter: pausing music while you dictate, bundled in `Packages/`
- [Zip](https://github.com/marmelroy/Zip): import and export
- [Swift Atomics](https://github.com/apple/swift-atomics): low-level thread safety
- LLMkit: the AI provider client, bundled in `Packages/`

**Fonts**
- [Figtree](https://github.com/erikdkennedy/figtree) and [EB Garamond](https://github.com/octaviopardo/EBGaramond12), under the SIL Open Font License

## License

Free Flow is released under the [GNU General Public License v3.0](LICENSE).

---

<sub>Portions of this app are derived, with modifications, from VoiceInk (GPL v3).</sub>
