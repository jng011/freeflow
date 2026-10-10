<!-- prettier-ignore -->
<div align="center">

<img src="./docs/images/icon.png" alt="Free Flow logo" width="128" />

# Free Flow

**The Wispr Flow workflow, free and open source.** Hold **fn**, talk, let go, and clean text appears wherever you're typing.

<a href="https://github.com/jng011/freeflow/releases/latest">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="./docs/images/download-dark.svg">
    <img src="./docs/images/download-light.svg" alt="Download Free Flow for Mac" height="38">
  </picture>
</a>

macOS 26+ &nbsp;·&nbsp; Apple Silicon &nbsp;·&nbsp; Free and open source

[Why](#why-free-flow) • [Features](#features) • [How it works](#how-it-works) • [Tour](#a-look-around) • [Install](#installation) • [Shortcuts](#shortcuts) • [AI agents](#let-ai-agents-see-your-dictations) • [Build from source](#build-from-source)

</div>

<p align="center">
  <img src="./docs/images/pill.png" alt="The Flow Bar: dictating, hands-free, prompt mode and Ask Siri" width="390">
</p>

Free Flow is a free, open-source take on Wispr Flow for the Mac. If you know Wispr Flow, you already know Free Flow: hold fn, talk, and polished text lands in whatever app you're using. Then it goes further, with transcription that can run entirely on your Mac, a prompt mode for AI assistants, voice filtering, and a door for your AI agents. No account, no subscription.

> [!TIP]
> Free Flow reads the **fn** key straight from the keyboard, so even quick double taps are caught reliably. Nothing to configure: just hold fn and talk.

## Why Free Flow

<table>
<tr>
<td width="50%" valign="top">

### Familiar by design
Hold fn to talk, double tap for hands-free, say "scratch that" to take it back. If you've used Wispr Flow, your hands already know Free Flow.

</td>
<td width="50%" valign="top">

### Yours, on your Mac
Transcribe on-device with Whisper, Parakeet or Apple Speech. No account, no sign-in, and your history stays in a folder you own.

</td>
</tr>
<tr>
<td width="50%" valign="top">

### Built for agents
A local MCP server lets Claude and other agents read your dictations, stats and dictionary, add words, and transcribe files.

</td>
<td width="50%" valign="top">

### Free and open
GPL v3, written in Swift, notarized by Apple, and updated automatically. Read every line, build it yourself, or just download it.

</td>
</tr>
</table>

## Features

### Everything you'd expect

- **Hold fn to talk.** Double tap fn for hands-free, tap again to stop. The key is read straight from the keyboard, so fast double taps are never missed.
- **Cleans up as you go.** Filler words, false starts and punctuation are fixed before the text is pasted. Use an OpenRouter, Anthropic or OpenAI key in **Settings > AI Cleanup**, or Apple Intelligence on-device where available.
- **"Scratch that."** Say it and the last thing you said is taken back.
- **Dictionary.** Teach it names and jargon once and it spells them your way.
- **Files.** Drop in a voice memo, meeting or video (MP3, M4A, WAV, MP4, MOV and more) for a clean transcript.
- **Insights.** Words per minute, streaks, and where you dictate most.
- **Light and dark mode.** Follow your Mac or pick one. Easy on the eyes at night.

### What Free Flow adds

- **On-device transcription.** Whisper, Parakeet or Apple Speech, running on your Mac.
- **Prompt mode.** Hold **Ctrl** with **fn** and a rambling request comes out as a clear, structured prompt for an AI assistant.
- **Ask Siri.** Start with "Ask Siri" and your words go straight to Siri.
- **Only your voice.** Free Flow learns your voice and can leave out other people talking nearby (**Settings > General > Voice**).
- **AI agent access.** A local MCP server for Claude and other agents.
- **Open source.** Every line is here. Fork it, fix it, make it yours.

> [!NOTE]
> Free Flow is young and moving fast. It runs on macOS 26 with Apple Silicon. Found a bug or want a feature? [Open an issue](https://github.com/jng011/freeflow/issues).

## How it works

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="./docs/images/how-it-works-dark.svg">
    <img src="./docs/images/how-it-works-light.svg" alt="Hold fn, talk, let go: clean text appears at your cursor" width="900">
  </picture>
</p>

1. **Hold fn** in any app and start talking. The Flow Bar shows that Free Flow is listening.
2. **Let go.** Your audio is transcribed on your Mac.
3. **Cleanup runs.** Your dictionary spellings are applied and, if enabled, AI cleanup fixes fillers, false starts and punctuation.
4. **Text appears** at your cursor, ready to send.


## A look around

<p align="center">
  <img src="./docs/images/light-dark.gif" alt="Free Flow in light and dark mode" width="900">
  <br><em>Light and dark, done properly. Follow your Mac or pick one; your eyes will thank you at 2 a.m.</em>
</p>

<table>
<tr>
<td width="50%" valign="top">

**Insights.** Words per minute, streaks, and where you dictate.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="./docs/images/insights-dark.png">
  <img src="./docs/images/insights-light.png" alt="Insights: words per minute, streaks and app usage">
</picture>

</td>
<td width="50%" valign="top">

**Your voice.** A profile of how you talk, refreshed as you dictate.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="./docs/images/voice-dark.png">
  <img src="./docs/images/voice-light.png" alt="Your voice profile">
</picture>

</td>
</tr>
<tr>
<td width="50%" valign="top">

**Dictionary.** Names and jargon, spelled your way.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="./docs/images/dictionary-dark.png">
  <img src="./docs/images/dictionary-light.png" alt="Dictionary of custom words">
</picture>

</td>
<td width="50%" valign="top">

**Files.** Drop in a recording, get a clean transcript.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="./docs/images/files-dark.png">
  <img src="./docs/images/files-light.png" alt="Files: transcribe recordings and videos">
</picture>

</td>
</tr>
</table>

## Requirements

| | |
|---|---|
| **macOS** | 26 or later |
| **Chip** | Apple Silicon (M1 or newer). Intel Macs aren't supported. |
| **Permissions** | Microphone, Accessibility, Input Monitoring |

## Installation

1. Download **`Free-Flow-<version>.dmg`** from the [latest release](https://github.com/jng011/freeflow/releases/latest).
2. Open it and drag **Free Flow** to **Applications**.
3. Open Free Flow and follow the setup. It asks for:
   - **Microphone:** only used while you dictate.
   - **Accessibility:** to paste into the app you're using.
   - **Input Monitoring:** to read the fn key directly from the keyboard.

> [!NOTE]
> The app is signed and notarized by Apple, so it opens without security warnings.

### Updates

Free Flow updates itself with [Sparkle](https://sparkle-project.org), installing new versions from this repository's [releases](https://github.com/jng011/freeflow/releases).

## Shortcuts

| Action | Shortcut |
|---|---|
| Dictate | Hold **fn**, release to finish |
| Hands-free | Double tap **fn**, tap again to stop |
| Prompt mode | Hold **Ctrl** + **fn** |
| Take back the last thing you said | Say "scratch that" |
| Send to Siri | Start with "Ask Siri" |

## Let AI agents see your dictations

Free Flow includes a local MCP server, so agents like Claude can:

- Read and search your dictation history
- See your stats
- Read your dictionary and add words
- Transcribe audio files through the app

Open Free Flow once, then run:

```sh
claude mcp add free-flow -- python3 "$HOME/Library/Application Support/com.jaydenghiyam.FreeFlow/freeflow_mcp.py"
```

> [!IMPORTANT]
> The server runs on your Mac. Nothing leaves it unless the agent sends it.

The same command is shown during onboarding and in **Settings > Data and Privacy**.

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

In Xcode, choose your own team under **Signing & Capabilities**, then press **Run** (Cmd+R).

> [!TIP]
> To build a signed Release copy or a notarized DMG from the command line, see [BUILDING.md](BUILDING.md). Swift packages built from source live in `Packages/`.

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

Portions of Free Flow are derived, with modifications, from VoiceInk (GPL v3).

---

Wispr Flow is a trademark of its owner. Free Flow is an independent, open-source project and is not affiliated with, sponsored by or endorsed by the makers of Wispr Flow. The name is used only to describe the workflow Free Flow follows.
