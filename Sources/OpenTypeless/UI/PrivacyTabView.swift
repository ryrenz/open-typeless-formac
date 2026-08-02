import SwiftUI

struct PrivacyTabView: View {
    let l: L

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

                PrivacyPolicyButton(l: l)

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

    private var title: String { l.lang == .zh ? "你的数据由你控制" : "You control your data" }
    private var dataFlowTitle: String { l.lang == .zh ? "网络数据" : "Network data" }
    private var dataFlowText: String {
        l.lang == .zh
            ? "只有在你同意后，录音、词典提示和转写文本才会直接发送到你选择的 OpenAI、Groq、Mistral 或自定义兼容端点。"
            : "Only after you consent, audio, dictionary hints, and transcript text are sent directly to the OpenAI, Groq, Mistral, or compatible endpoint you select."
    }
    private var localDataTitle: String { l.lang == .zh ? "本地数据" : "Local data" }
    private var localDataText: String {
        l.lang == .zh
            ? "历史记录和失败录音保存在这台 Mac 上。可分别在“历史记录”和“失败录音”页面删除。"
            : "History and failed recordings stay on this Mac. Delete them from the History and Failed Recordings pages."
    }
    private var apiKeyTitle: String { "API Key" }
    private var apiKeyText: String {
        l.lang == .zh
            ? "API Key 保存在 macOS Keychain，不写入 UserDefaults、日志或项目文件。"
            : "Your API key is stored in macOS Keychain, never in UserDefaults, logs, or project files."
    }
    private var trackingTitle: String { l.lang == .zh ? "追踪与分析" : "Tracking and analytics" }
    private var trackingText: String {
        l.lang == .zh
            ? "OpenTypeless 不包含广告、追踪或开发者分析服务，也不会把转写内容发送给 OpenTypeless 开发者。"
            : "OpenTypeless contains no ads, tracking, or developer analytics, and does not send transcription content to the OpenTypeless developer."
    }
    private var manageDataHint: String {
        l.lang == .zh
            ? "服务商对网络请求的处理方式由其自身隐私政策决定。"
            : "The selected provider handles network requests under its own privacy policy."
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
    let l: L
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Label(
                l.lang == .zh ? "查看完整隐私政策" : "Read the full privacy policy",
                systemImage: "doc.text"
            )
        }
        .buttonStyle(.link)
        .sheet(isPresented: $isPresented) {
            PrivacyPolicySheet(l: l)
        }
    }
}

private struct PrivacyPolicySheet: View {
    let l: L
    @Environment(\.dismiss) private var dismiss

    private var policyText: String {
        PrivacyPolicyDocument.load()
            ?? (l.lang == .zh
                ? "无法载入内置隐私政策。请重新安装 OpenTypeless。"
                : "The bundled privacy policy could not be loaded. Reinstall OpenTypeless.")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(l.lang == .zh ? "隐私政策" : "Privacy Policy")
                    .font(.headline)
                Spacer()
                Button(l.lang == .zh ? "完成" : "Done") {
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
