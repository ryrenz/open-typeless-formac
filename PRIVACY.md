# OpenTypeless Privacy Policy

Last updated: July 30, 2026

OpenTypeless is an open-source macOS speech-to-text utility. It does not include advertising, tracking, telemetry, or developer-operated analytics.

## Data sent to a transcription provider

OpenTypeless sends data only after you accept the in-app data-processing disclosure. The following data is sent directly from your Mac to the provider and endpoint you select:

- Voice recordings required for transcription.
- Personal dictionary terms used as spelling hints.
- Transcript text sent for formatting.

The default provider is OpenAI. You may instead configure an OpenAI-compatible endpoint. The selected provider receives and processes these requests under its own terms and privacy policy, and may link them to the account associated with your API key. OpenTypeless and its developer do not proxy, receive, or store these network requests.

Changing the provider or custom endpoint requires consent for the new destination before another request can be sent.

## Data stored on your Mac

OpenTypeless stores the following data locally:

- Your API key in macOS Data Protection Keychain. The app uses only the key you enter in Settings and does not read API keys from environment variables or developer-managed secret stores.
- Transcription history in a local SQLite database.
- Failed recordings and recovery metadata in Application Support when a transcription request fails.
- App preferences, including hotkeys, provider, model, custom endpoint, language, and data-processing consent, in UserDefaults.
- Transcription text temporarily in the clipboard when clipboard-based insertion or recovery is needed.

You can delete an individual history entry, clear all history, delete an individual failed recording, or delete all failed recordings from Settings. You can also delete your API key from the API page. These deletions are permanent.

## Permissions

OpenTypeless requests:

- Microphone access to record audio for transcription.
- Accessibility access to insert transcription results into the app you were using and to operate the global shortcut.

OpenTypeless does not use these permissions for analytics, advertising, or tracking.

## Clipboard behavior

For apps that require paste-based insertion, OpenTypeless temporarily places the transcription on the clipboard, sends Command-V, and restores the previous clipboard value when it can do so safely. On insertion failure, the transcription may remain available for a short recovery window.

## Children

OpenTypeless is a general productivity tool and is not directed to children.

## Changes and contact

Material changes will be documented in this file. For privacy questions or reports, open an issue in the [OpenTypeless GitHub repository](https://github.com/ryrenz/open-typeless-formac/issues).
