# open-typeless-formac

[English](README.md) | [中文](README_CN.md)

An open-source macOS menu bar app for speech-to-text. Press a hotkey to start recording, press again to stop — your speech is transcribed and automatically inserted into the active text field.

Current public release: **v1.0.1** (universal, signed, and notarized).

Inspired by [Typeless](https://www.typeless.com/).

## Features

- **Toggle-to-talk**: Press hotkey to start, press again to stop (no need to hold)
- **Auto-insert**: Uses Accessibility insertion where reliable, with guarded clipboard paste for compatibility targets
- **Popup fallback**: If no text field is focused, a floating panel shows the result with a Copy button
- **Progress overlay**: A bottom-center overlay shows recording/transcribing status with audio level
- **Double-tap cancel**: Quickly press the hotkey twice to cancel recording
- **Multiple providers and models**: Built-in OpenAI, Groq, and Mistral presets, plus custom OpenAI-compatible endpoints; Groq audio requests remove the SDK's default `stream=false` field for incompatible endpoints
- **Multilingual transcription**: Groq `whisper-large-v3-turbo` / `whisper-large-v3`, Mistral `voxtral-mini-latest`, and OpenAI transcription models
- **Smart formatting**: Transcription output is automatically post-processed — Chinese punctuation for Chinese/mixed content, English punctuation for English-only, pangu-style spacing between CJK and Latin, natural paragraph breaks, and enumeration converted to numbered lists (1. 2. 3.)
- **Dictionary**: Add proper nouns (product names, people, jargon) that are often misrecognized. Entries are sent as transcription hints where the selected provider supports that field, and silent hallucinations of dictionary terms are filtered out.
- **History**: Browse, copy, delete individual entries, clear all entries, and choose a local retention policy.
- **Failed recording recovery**: Network/API failures preserve the original recording locally; reveal or permanently delete individual/all recordings in Settings.
- **Crash-safe private configuration**: The API key, Provider, endpoint, and model are committed atomically as one versioned macOS Keychain item in both development and release builds.
- **Chinese/English UI**: Switch UI language in Settings

## Quick Start

### 1. Download and Install

1. Download the latest signed and notarized DMG from [GitHub Releases](https://github.com/ryrenz/open-typeless-formac/releases/latest)
2. Open the DMG and drag `OpenTypeless.app` to `/Applications`
3. Launch OpenTypeless from `/Applications`

### 2. Find the App

After launching the app, look for the **microphone icon (🎙) in the top-right menu bar** — that's open-typeless. Click it to access Settings.

### 3. Grant Permissions

On first launch, you'll be prompted to grant:
- **Microphone** — for recording your voice
- **Accessibility** — for the global hotkey and text insertion

> If you use stable local signing, Accessibility permission usually persists across rebuilds. Otherwise, after each build you may need to re-grant: go to System Settings > Privacy & Security > Accessibility, remove the old entry with the minus (-) button, then click "Grant Access" in the app to re-add it.

### 4. Configure API Key

When the API configuration is incomplete, OpenTypeless opens the required setup automatically on launch. A hotkey attempt also opens the same setup **before recording starts**, so no audio is recorded without a configured destination and your consent.

- **Provider**: Choose OpenAI, Groq, Mistral, or Custom (for another OpenAI-compatible endpoint)
- **API Key**: Enter the key for the selected provider; it is stored only in the macOS Keychain
- **Model**: Built-in providers show their supported models; Custom accepts a provider-supplied model ID
- **Data processing**: Review the exact destination, read the bundled privacy policy, accept the disclosure, and continue. A new Provider or Custom endpoint needs its own consent; destinations you already approved are remembered. Clearing the checkbox revokes the current destination immediately, cancels its active network work, and Settings can revoke every saved destination at once. Re-approving a destination does not revive an older recording session.

Get keys from [OpenAI](https://platform.openai.com/api-keys), [Groq](https://console.groq.com/keys), or [Mistral](https://console.mistral.ai/api-keys).

The app never reads an API key from environment variables. Development builds follow the same App → Keychain path as release builds. An interrupted settings save can retain only the complete old snapshot or the complete new snapshot, never a mixed key/endpoint pair.

If a saved configuration becomes unreadable or comes from a newer app version, the required setup screen fails closed and offers an explicit reset or replacement path instead of sending audio with fallback settings.

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

OpenTypeless includes OpenAI, Groq, and Mistral transcription models. New users can choose Groq for the lowest transcription cost; upgrades do not overwrite an existing provider selection.

| Usage | Cost (USD) | Cost (CNY) |
|-------|-----------|------------|
| 1 minute (~150 words) | $0.003 | ~0.02 |
| 10 minutes | $0.03 | ~0.2 |
| 1 hour | $0.18 | ~1.3 |
| Daily use (30 min/day, 1 month) | ~$2.70 | ~20 |

> For comparison: Typeless costs $144/year. With open-typeless, even heavy daily use costs under $3/month.

| Model | Cost/min | Accuracy |
|-------|----------|----------|
| gpt-4o-mini-transcribe | $0.003 | Great (OpenAI default) |
| gpt-4o-transcribe | $0.006 | Best |
| whisper-1 | $0.006 | Good |
| Groq whisper-large-v3-turbo | ~$0.0007 | Very fast, multilingual |
| Groq whisper-large-v3 | ~$0.0019 | Multilingual, accuracy first |
| Mistral voxtral-mini-latest | $0.003 | Multilingual |

Groq Turbo is about 22% of the `gpt-4o-mini-transcribe` transcription price, at roughly $0.04/hour. Mistral and OpenAI mini are currently both about $0.003/minute. Prices change; see the [Groq model prices](https://console.groq.com/docs/models), [Mistral API pricing](https://mistral.ai/pricing/api/), and [OpenAI API pricing](https://platform.openai.com/pricing). Groq bills a minimum of 10 seconds per request.

## Tech Stack

| Layer | Technology |
|-------|-----------|
| App | Swift + SwiftUI + AppKit (MenuBarExtra + NSWindow) |
| Audio | AVAudioRecorder (M4A, 44.1kHz mono) |
| Transcription | [MacPaw/OpenAI](https://github.com/MacPaw/OpenAI) Swift SDK + provider compatibility middleware |
| Text insertion | Accessibility direct insertion + guarded temporary clipboard/Cmd+V fallback |
| Hotkeys | CGEvent tap (toggle mode, modifier-only key support) |

## Privacy and Local Data

OpenTypeless has no ads, tracking, telemetry, or developer-operated analytics. Audio, dictionary hints, and transcript text are sent directly to the provider you select only after you consent. History and failed recordings remain on your Mac and can be deleted in Settings. See the full [Privacy Policy](PRIVACY.md).

## Local Development Build and DMG

Do not copy every Xcode build into `/Applications`. Xcode keeps its incremental build product in `.build/DerivedData`; the local install script replaces the one canonical app path and restores the previous app automatically if validation fails:

```bash
scripts/install-local.sh
```

To build without launching the app, or to use a Release build locally:

```bash
scripts/install-local.sh --configuration Release --no-launch
```

To create a local, non-notarized test DMG with isolated temporary staging:

```bash
scripts/build-dmg.sh
```

The output is `dist/local/OpenTypeless-<version>.dmg` plus a SHA-256 checksum. Local artifacts are kept separate from the formal `dist/` release directory and are never overwritten unless `--force` is explicit. These scripts do not upload to GitHub; use `scripts/release-dmg.sh` for the public universal notarized release.

## Creating a Notarized DMG

Public distribution requires an Apple **Developer ID Application** certificate and a notary credential stored in Keychain. The release script does not upload anything to GitHub.

1. Install one usable Developer ID Application certificate for the team you will pass to `--team-id`.
2. Store Apple notarization credentials once:
   ```bash
   xcrun notarytool store-credentials OpenTypelessNotary \
     --apple-id "your-apple-id@example.com" \
     --team-id "YOURTEAMID"
   ```
   `notarytool` prompts for the app-specific password and stores the resulting profile in Keychain.
3. Commit all release changes and create a version tag that points to that commit, then verify prerequisites:
   ```bash
   scripts/release-dmg.sh \
     --version 1.0.1 \
     --build 2 \
     --team-id YOURTEAMID \
     --tag v1.0.1 \
     --preflight-only
   ```
4. Create, notarize, staple, and verify the universal DMG:
   ```bash
   scripts/release-dmg.sh \
     --version 1.0.1 \
     --build 2 \
     --team-id YOURTEAMID \
     --tag v1.0.1
   ```

The output is written to `dist/OpenTypeless-<version>.dmg` with a SHA-256 checksum. Any signing, notarization, stapling, Gatekeeper, or architecture check failure stops the release.

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Hotkey doesn't work | Keep running the same signed app from `/Applications`; if macOS shows access as disabled, re-enable OpenTypeless in Accessibility settings |
| "API key not configured" | Enter your key in Settings → API tab |
| Data processing consent required | Review and accept the disclosure in Settings → API |
| No audio input | Check System Settings > Sound > Input; make sure a microphone is selected |
| Text not inserting | Click into a text field before stopping the recording |
| Can't find the app | Look for the microphone icon in the top-right menu bar |

## License

MIT
