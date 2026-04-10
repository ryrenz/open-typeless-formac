# open-typeless-formac

[English](README.md) | [中文](README_CN.md)

An open-source macOS menu bar app for speech-to-text. Press a hotkey to start recording, press again to stop — your speech is transcribed and automatically inserted into the active text field.

Inspired by [Typeless](https://www.typeless.com/).

## Features

- **Toggle-to-talk**: Press hotkey to start, press again to stop (no need to hold)
- **Auto-insert**: Transcribed text is pasted into the focused input field via Cmd+V
- **Popup fallback**: If no text field is focused, a floating panel shows the result with a Copy button
- **Progress overlay**: A bottom-center overlay shows recording/transcribing status with audio level
- **Double-tap cancel**: Quickly press the hotkey twice to cancel recording
- **Multiple models**: Choose between gpt-4o-mini-transcribe, gpt-4o-transcribe, or whisper-1
- **Custom API endpoint**: Works with any OpenAI-compatible API (Groq, Together AI, etc.)
- **Chinese/English UI**: Switch UI language in Settings

## Quick Start

### 1. Build & Run

1. Download **Xcode** from the [App Store](https://apps.apple.com/app/xcode/id497799835) (requires macOS 14.0+)
2. Clone this repo:
   ```bash
   git clone https://github.com/scinttt/open-typeless-formac.git
   ```
3. Open `OpenTypeless.xcodeproj` in Xcode
4. Press **Cmd+R** to build and run

### 2. Find the App

After build & run, look for the **microphone icon (🎙) in the top-right menu bar** — that's open-typeless. Click it to access Settings.

### 3. Grant Permissions

On first launch, you'll be prompted to grant:
- **Microphone** — for recording your voice
- **Accessibility** — for the global hotkey and text insertion

> After each build, you need to grant Accessibility again: go to System Settings > Privacy & Security > Accessibility, remove the old entry with the minus (-) button, then click "Grant Access" in the app to re-add it.

### 4. Configure API Key

Click the menu bar icon → **Settings** → go to the **API** tab:
- **Provider**: Choose "OpenAI" or "Custom" (for OpenAI-compatible endpoints)
- **API Key**: Enter your OpenAI API key (`sk-...`)
- **Model**: Choose a transcription model (default: `gpt-4o-mini-transcribe`)

You can get an OpenAI API key at [platform.openai.com/api-keys](https://platform.openai.com/api-keys).

### 5. Start Using

> **⚠️ Default Hotkey: Right Option (Alt) key**
>
> This is the key to the left of the arrow keys on most keyboards.

| Action | How |
|--------|-----|
| **Start recording** | Press **Right Option (Alt)** |
| **Stop & transcribe** | Press **Right Option (Alt)** again |
| **Cancel recording** | Double-press **Right Option (Alt)** quickly |

The transcribed text will be automatically inserted into whatever text field your cursor is in. If no text field is focused, a popup appears with a Copy button.

> The hotkey can be customized in Settings → Hotkeys tab. Click "Click to record" then press your desired key or key combo.

## Pricing Estimate

open-typeless uses the `gpt-4o-mini-transcribe` model by default.

| Usage | Cost (USD) | Cost (CNY) |
|-------|-----------|------------|
| 1 minute (~150 words) | $0.003 | ~0.02 |
| 10 minutes | $0.03 | ~0.2 |
| 1 hour | $0.18 | ~1.3 |
| Daily use (30 min/day, 1 month) | ~$2.70 | ~20 |

> For comparison: Typeless costs $144/year. With open-typeless, even heavy daily use costs under $3/month.

| Model | Cost/min | Accuracy |
|-------|----------|----------|
| gpt-4o-mini-transcribe | $0.003 | Great (default) |
| gpt-4o-transcribe | $0.006 | Best |
| whisper-1 | $0.006 | Good |

## Tech Stack

| Layer | Technology |
|-------|-----------|
| App | Swift + SwiftUI + AppKit (MenuBarExtra + NSWindow) |
| Audio | AVAudioRecorder (M4A, 44.1kHz mono) |
| Transcription | [MacPaw/OpenAI](https://github.com/MacPaw/OpenAI) Swift SDK |
| Text insertion | Clipboard + simulated Cmd+V |
| Hotkeys | CGEvent tap (toggle mode, modifier-only key support) |

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Hotkey doesn't work | Check Accessibility permission; remove old entry and re-add in System Settings |
| "API key not configured" | Enter your key in Settings → API tab |
| No audio input | Check System Settings > Sound > Input; make sure a microphone is selected |
| Text not inserting | Click into a text field before stopping the recording |
| Can't find the app | Look for the microphone icon in the top-right menu bar |

## License

MIT
