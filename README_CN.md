# open-typeless-formac

[English](README.md) | [中文](README_CN.md)

一个开源的 macOS 菜单栏语音转文字工具。按下快捷键开始录音，再按一下停止——语音自动转写并插入到当前输入框中。

灵感来源于 [Typeless](https://www.typeless.com/)。

## 功能

- **按键切换录音**：按一下开始录音，再按一下停止（不需要一直按着）
- **自动插入**：可靠目标走 Accessibility；兼容性目标使用带前台校验的临时剪贴板粘贴
- **弹窗兜底**：如果没有聚焦的输入框，弹出浮窗显示结果并提供复制按钮
- **进度浮窗**：屏幕底部居中显示录音/转写状态和实时音量
- **双击取消**：快速按两下快捷键取消录音
- **多模型可选**：支持 gpt-4o-mini-transcribe、gpt-4o-transcribe、whisper-1
- **自定义 API**：兼容任何 OpenAI 兼容端点（Groq、Together AI 等）
- **智能排版**：转写结果自动后处理——中文或中英混合内容使用中文标点，纯英文使用英文标点；中文与英文/数字之间自动加空格（pangu 风格）；自然段落分行；口述的列举内容转换为编号列表（1. 2. 3.）。
- **词汇表**：添加容易被误识别的专有名词（产品名、人名、术语等），作为转写提示发给模型，帮助它优先使用正确拼写；并过滤掉模型在静默时对词汇表词的幻听输出。
- **历史记录**：可浏览、复制、单条删除、全部清空，并可选择本地保留策略。
- **失败录音恢复**：网络/API 失败时保留原始录音，可在设置中通过 Finder 查看、单条删除或全部删除。
- **崩溃安全的私密配置**：开发版与发布版都把 API Key、Provider、endpoint 和模型作为一个版本化配置，原子保存到 macOS Keychain。
- **中英文界面**：设置中可切换界面语言

## 快速开始

### 1. 编译运行

1. 从 [App Store](https://apps.apple.com/app/xcode/id497799835) 下载 **Xcode**
2. 克隆本仓库：
   ```bash
   git clone https://github.com/ryrenz/open-typeless-formac.git
   ```
3. 用 Xcode 打开 `OpenTypeless.xcodeproj`
4. 按 **Cmd+R** 编译运行

### 2. 找到应用

编译运行后，在屏幕**右上角菜单栏**找到 **麦克风图标（🎙）**——这就是 open-typeless。点击它可以进入设置。

### 3. 授权权限

首次启动时会提示授权：
- **麦克风** — 用于录音
- **辅助功能** — 用于全局快捷键和文字插入

> 重新编译后如果 Accessibility 权限失效，前往系统设置 > 隐私与安全性 > 辅助功能，用减号（-）删掉旧条目，然后在 app 中点击“授权”重新添加。

### 4. 配置 API Key

API 配置不完整时，OpenTypeless 会在启动后直接打开必需设置。如果用户先按了快捷键，也会在**开始录音前**打开同一个设置流程；未配置接收方和完成同意之前不会录音。

- **Provider**：选择 "OpenAI" 或 "Custom"（用于 OpenAI 兼容端点）
- **API Key**：输入你的 OpenAI API key（`sk-...`）
- **Model**：选择转写模型（默认：`gpt-4o-mini-transcribe`）
- **数据处理**：核对确切发送地址、阅读 App 内置隐私政策、勾选同意并继续。新的 Provider 或 Custom endpoint 需要单独确认；已经确认过的目的地会被记住。取消勾选会立即撤销当前目的地的同意并取消对应的活动网络任务，设置页也可以一次撤销全部已保存目的地；重新同意不会让旧录音会话恢复发送。

OpenAI API key 获取地址：[platform.openai.com/api-keys](https://platform.openai.com/api-keys)

App 不读取环境变量中的 API Key。开发测试与普通用户使用完全相同的 App → Keychain 路径。设置保存即使中途被强退，也只会保留完整旧快照或完整新快照，不会出现新 Key 与旧 endpoint 混用。

如果已保存配置损坏，或由更高版本的 App 写入，必需设置页会停止转写并提供明确的重置或覆盖入口，不会使用回退地址发送录音。

### 5. 开始使用

> **⚠️ 默认快捷键：右 Option（Alt）键**
>
> 就是键盘上方向键左边的那个键。

| 操作 | 方法 |
|------|------|
| **开始录音** | 按 **右 Option（Alt）键** |
| **停止并转写** | 再按一次 **右 Option（Alt）键** |
| **取消录音** | 快速按两下 **右 Option（Alt）键** |

转写文字会自动插入到光标所在的输入框中。如果没有输入框聚焦，会弹出浮窗并提供复制按钮。

> 快捷键可以在设置 → 快捷键标签页中自定义：点击"Click to record"，然后按下你想要的按键或组合键。

## 费用估算

默认使用 `gpt-4o-mini-transcribe` 模型。

| 使用量 | 费用（美元） | 费用（人民币） |
|--------|-------------|---------------|
| 1 分钟（约 150 字） | $0.003 | 约 0.02 元 |
| 10 分钟 | $0.03 | 约 0.2 元 |
| 1 小时 | $0.18 | 约 1.3 元 |
| 日常使用（每天 30 分钟，1 个月） | 约 $2.70 | 约 20 元 |

> 对比：Typeless 售价 $144/年。使用 open-typeless，即使重度使用每月也不到 $3。

| 模型 | 费用/分钟 | 准确度 |
|------|----------|--------|
| gpt-4o-mini-transcribe | $0.003 | 很好（默认） |
| gpt-4o-transcribe | $0.006 | 最好 |
| whisper-1 | $0.006 | 好 |

## 技术栈

| 层级 | 技术 |
|------|------|
| 应用框架 | Swift + SwiftUI + AppKit（MenuBarExtra + NSWindow） |
| 音频录制 | AVAudioRecorder（M4A, 44.1kHz 单声道） |
| 语音转写 | [MacPaw/OpenAI](https://github.com/MacPaw/OpenAI) Swift SDK |
| 文字插入 | Accessibility 直接写入 + 带前台校验的临时剪贴板/Cmd+V 兜底 |
| 全局快捷键 | CGEvent tap（切换模式，支持单修饰键） |

## 隐私与本地数据

OpenTypeless 不包含广告、追踪、遥测或开发者分析。只有在你同意后，录音、词典提示和转写文本才会直接发送到所选服务商。历史记录和失败录音只保存在本机，并可在设置中删除。完整说明见[隐私政策](PRIVACY.md)。

## 生成已公证的 DMG

公开分发需要 Apple **Developer ID Application** 证书，以及保存在 Keychain 中的 notarization 凭证。请先在 Xcode 登录对应的 Apple Developer 账号，自动签名会创建或下载 API Key 的 Keychain access group 所需的开发与 Developer ID provisioning profile。发布脚本不会自动上传 GitHub。

1. 在登录 Keychain 中安装一张属于 `--team-id` 所指定团队的可用 Developer ID Application 证书。
2. 一次性保存 Apple notarization 凭证：
   ```bash
   xcrun notarytool store-credentials OpenTypelessNotary \
     --apple-id "your-apple-id@example.com" \
     --team-id "YOURTEAMID"
   ```
   `notarytool` 会提示输入 app-specific password，并将 profile 保存到 Keychain。
3. 提交全部发布变更并为该 commit 创建版本 tag 后，先检查环境：
   ```bash
   scripts/release-dmg.sh \
     --version 1.0.0 \
     --build 1 \
     --team-id YOURTEAMID \
     --tag v1.0.0 \
     --preflight-only
   ```
4. 生成、notarize、staple 并验证 universal DMG：
   ```bash
   scripts/release-dmg.sh \
     --version 1.0.0 \
     --build 1 \
     --team-id YOURTEAMID \
     --tag v1.0.0
   ```

产物位于 `dist/OpenTypeless-<version>.dmg`，同时生成 SHA-256 校验文件。签名、公证、staple、Gatekeeper 或架构检查任何一步失败，脚本都会停止。

## 常见问题

| 问题 | 解决方案 |
|------|---------|
| 快捷键不工作 | 始终从 `/Applications` 运行同一个已签名应用；若 macOS 显示权限已关闭，请在辅助功能设置中重新启用 OpenTypeless |
| "API key not configured" | 在设置 → API 标签页中输入 API key |
| 提示需要同意数据处理 | 在设置 → API 阅读并勾选数据处理说明 |
| 没有音频输入 | 检查系统设置 > 声音 > 输入，确保选择了麦克风 |
| 文字没有插入 | 停止录音前先点击目标输入框 |
| 找不到应用 | 看右上角菜单栏的麦克风图标 |

## 许可证

MIT
