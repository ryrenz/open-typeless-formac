import SwiftUI

struct PrivacyTabView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(title)
                    .font(.title2.weight(.semibold))

                privacySection(
                    title: dataFlowTitle,
                    systemImage: "network",
                    text: dataFlowText
                )
                privacySection(
                    title: localDataTitle,
                    systemImage: "internaldrive",
                    text: localDataText
                )
                privacySection(
                    title: apiKeyTitle,
                    systemImage: "key",
                    text: apiKeyText
                )
                privacySection(
                    title: trackingTitle,
                    systemImage: "eye.slash",
                    text: trackingText
                )

                PrivacyPolicyButton()

                Text(manageDataHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
    }

    private func privacySection(
        title: String,
        systemImage: String,
        text: String
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .frame(width: 22)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(text)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var title: String { "You control your data" }
    private var dataFlowTitle: String { "Network data" }
    private var dataFlowText: String {
        "Only after you consent, audio, dictionary hints, and transcript text are sent directly to the OpenAI, Groq, Mistral, or compatible endpoint you select."
    }
    private var localDataTitle: String { "Local data" }
    private var localDataText: String {
        "History and failed recordings stay on this Mac. Delete them from the History and Failed Recordings pages."
    }
    private var apiKeyTitle: String { "API Key" }
    private var apiKeyText: String {
        "Your API key is stored in macOS Keychain, never in UserDefaults, logs, or project files."
    }
    private var trackingTitle: String { "Tracking and analytics" }
    private var trackingText: String {
        "OpenTypeless contains no ads, tracking, or developer analytics, and does not send transcription content to the OpenTypeless developer."
    }
    private var manageDataHint: String {
        "The selected provider handles network requests under its own privacy policy."
    }

}

enum PrivacyPolicyDocument {
    static func load(bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: "PRIVACY", withExtension: "md") else {
            return nil
        }
        return load(url: url)
    }

    static func load(url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }
}

struct PrivacyPolicyButton: View {
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Label(
                "Read the full privacy policy",
                systemImage: "doc.text"
            )
        }
        .buttonStyle(.link)
        .sheet(isPresented: $isPresented) {
            PrivacyPolicySheet()
        }
    }
}

private struct PrivacyPolicySheet: View {
    @Environment(\.dismiss) private var dismiss

    private var policyText: String {
        PrivacyPolicyDocument.load()
            ?? "The bundled privacy policy could not be loaded. Reinstall OpenTypeless."
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Privacy Policy")
                    .font(.headline)
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(16)

            Divider()

            ScrollView {
                Text(policyText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(20)
            }
        }
        .frame(width: 580, height: 520)
    }
}
