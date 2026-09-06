# open-typeless-formac

[English](README.md) | [中文](README_CN.md)

一个开源的 macOS 菜单栏语音转文字工具。按下快捷键开始录音，再按一下停止——语音自动转写并插入到当前输入框中。

当前公开版本：**v1.0.1**（universal、已签名并完成 notarization）。

灵感来源于 [Typeless](https://www.typeless.com/)。

## 功能

- **按键切换录音**：按一下开始录音，再按一下停止（不需要一直按着）
- **自动插入**：可靠目标走 Accessibility；兼容性目标使用带前台校验的临时剪贴板粘贴
- **弹窗兜底**：如果没有聚焦的输入框，弹出浮窗显示结果并提供复制按钮
- **进度浮窗**：屏幕底部居中显示录音/转写状态和实时音量
- **双击取消**：快速按两下快捷键取消录音
- **多 Provider 与模型**：内置 OpenAI、Groq、Mistral 预设，也支持自定义 OpenAI 兼容端点；Groq 音频请求兼容不接受 SDK 默认 `stream=false` 的端点
- **多语言转写**：Groq `whisper-large-v3`（推荐默认）/ `whisper-large-v3-turbo`，Mistral `voxtral-mini-latest`，以及 OpenAI 转写模型
- **智能排版**：转写结果自动后处理——中文或中英混合内容使用中文标点，纯英文使用英文标点；中文与英文/数字之间自动加空格（pangu 风格）；自然段落分行；口述的列举内容转换为编号列表（1. 2. 3.）。
- **词汇表**：添加容易被误识别的专有名词（产品名、人名、术语等），在支持提示词的 Provider 上帮助模型优先使用正确拼写；并过滤掉模型在静默时对词汇表词的幻听输出。
- **历史记录**：可浏览、复制、单条删除、全部清空，并可选择本地保留策略。
- **失败录音恢复**：网络/API 失败时保留原始录音，可在设置中通过 Finder 查看、单条删除或全部删除。
- **崩溃安全的私密配置**：开发版与发布版都把 API Key、Provider、endpoint 和模型作为一个版本化配置，原子保存到 macOS Keychain。
- **英文界面**：应用界面与内置产品文案统一使用英文

## 快速开始

### 1. 下载并安装

1. 从 [GitHub Releases](https://github.com/ryrenz/open-typeless-formac/releases/latest) 下载最新的已签名、公证 DMG
2. 打开 DMG，将 `OpenTypeless.app` 拖到 `/Applications`
3. 从 `/Applications` 启动 OpenTypeless

### 2. 找到应用

启动应用后，在屏幕**右上角菜单栏**找到 **麦克风图标（🎙）**——这就是 open-typeless。点击它可以进入设置。

### 3. 授权权限

首次启动时会提示授权：
- **麦克风** — 用于录音
- **辅助功能** — 用于全局快捷键和文字插入

> 重新编译后如果 Accessibility 权限失效，前往系统设置 > 隐私与安全性 > 辅助功能，用减号（-）删掉旧条目，然后在 app 中点击“授权”重新添加。

### 4. 配置 API Key

API 配置不完整时，OpenTypeless 会在启动后直接打开必需设置。如果用户先按了快捷键，也会在**开始录音前**打开同一个设置流程；未配置接收方和完成同意之前不会录音。

- **Provider**：选择 OpenAI、Groq、Mistral，或 Custom（用于其他 OpenAI 兼容端点）
- **API Key**：输入所选 Provider 的 API Key；Key 只保存到 macOS Keychain
- **Model**：内置 Provider 会显示可用模型；Custom 可填写服务商提供的模型 ID
- **数据处理**：核对确切发送地址、阅读 App 内置隐私政策、勾选同意并继续。新的 Provider 或 Custom endpoint 需要单独确认；已经确认过的目的地会被记住。取消勾选会立即撤销当前目的地的同意并取消对应的活动网络任务，设置页也可以一次撤销全部已保存目的地；重新同意不会让旧录音会话恢复发送。

API Key 获取地址：[OpenAI](https://platform.openai.com/api-keys)、[Groq](https://console.groq.com/keys)、[Mistral](https://console.mistral.ai/api-keys)

**Groq 推荐：** 新的 Groq 配置默认使用 `whisper-large-v3`，因为它更优先保证多语言准确度。目前 Groq Free tier 对 `whisper-large-v3` 和 `whisper-large-v3-turbo` 提供相同限额：每分钟 20 次、每天 2,000 次、每小时 7,200 秒音频、每天 28,800 秒音频。因此在重视准确度时，`large-v3` 更适合作为默认模型。这是有速率限制的免费使用，并不是无限额度；具体限额请以 Groq [最新官方限制](https://console.groq.com/docs/rate-limits) 为准。

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

应用内置 OpenAI、Groq、Mistral 三类转写模型。新用户默认选择 Groq `whisper-large-v3` 作为免费层准确度优先的选项；如果更看重速度或未来的付费成本，仍可切换到 `whisper-large-v3-turbo`。已有 Provider 和模型配置不会被发布升级自动覆盖。

| 使用量 | 费用（美元） | 费用（人民币） |
|--------|-------------|---------------|
| 1 分钟（约 150 字） | $0.003 | 约 0.02 元 |
| 10 分钟 | $0.03 | 约 0.2 元 |
| 1 小时 | $0.18 | 约 1.3 元 |
| 日常使用（每天 30 分钟，1 个月） | 约 $2.70 | 约 20 元 |

> 对比：Typeless 售价 $144/年。使用 open-typeless，即使重度使用每月也不到 $3。

| 模型 | 费用/分钟 | 准确度 |
|------|----------|--------|
| gpt-4o-mini-transcribe | $0.003 | 很好（OpenAI 默认） |
| gpt-4o-transcribe | $0.006 | 最好 |
| whisper-1 | $0.006 | 好 |
| Groq whisper-large-v3 | 约 $0.0019 | 推荐默认，多语言，准确度优先 |
| Groq whisper-large-v3-turbo | 约 $0.0007 | 更快，付费使用更便宜 |
| Mistral voxtral-mini-latest | $0.003 | 多语言 |

Groq `whisper-large-v3` 优先准确度；Turbo 更快，付费使用约为每小时 $0.04，成本约低至前者的 36%。Mistral 与 OpenAI mini 目前都是约 $0.003/分钟。价格和免费层限额都会变化，请以 Groq [官方语音转写说明](https://console.groq.com/docs/speech-to-text)、[模型价格](https://console.groq.com/docs/models) 与 [速率限制](https://console.groq.com/docs/rate-limits)，以及 [Mistral 官方 API 定价](https://mistral.ai/pricing/api/) 和 [OpenAI 官方 API 定价](https://platform.openai.com/pricing) 为准。Groq 付费使用每次请求最低按 10 秒计费。

## 本地微调模型

本仓库包含一个可复现实验:用 rank-32 LoRA 将多语言 Whisper-small 适配到中英混合的技术演讲语音。在 11,919 条 held-out 测试集上,字错误率从 25.5% 降到 8.5%;在领域内语音上超过体量为其 6 倍的云端 `whisper-large-v3`。14 MB 的 adapter 已发布于 [https://huggingface.co/Creaturelove7/whisper-small-lora-ntu-ml2021](https://huggingface.co/Creaturelove7/whisper-small-lora-ntu-ml2021),完整的版本锁定训练与评测管道在 [`training/ntu_ml2021`](training/ntu_ml2021)。

## 技术栈

| 层级 | 技术 |
|------|------|
| 应用框架 | Swift + SwiftUI + AppKit（MenuBarExtra + NSWindow） |
| 音频录制 | AVAudioRecorder（M4A, 44.1kHz 单声道） |
| 语音转写 | [MacPaw/OpenAI](https://github.com/MacPaw/OpenAI) Swift SDK + Provider 兼容 middleware |
| 文字插入 | Accessibility 直接写入 + 带前台校验的临时剪贴板/Cmd+V 兜底 |
| 全局快捷键 | CGEvent tap（切换模式，支持单修饰键） |

## 隐私与本地数据

OpenTypeless 不包含广告、追踪、遥测或开发者分析。只有在你同意后，录音、词典提示和转写文本才会直接发送到所选服务商。历史记录和失败录音只保存在本机，并可在设置中删除。完整说明见[隐私政策](PRIVACY.md)。

## 本地开发构建与 DMG 测试

不要把每次 Xcode 构建都手动复制到 `/Applications`。Xcode 的增量构建统一保存在 `.build/DerivedData`；本地安装脚本只维护一个标准路径，并在校验失败时自动恢复旧 App：

```bash
scripts/install-local.sh
```

如果只想构建不启动，或要本地测试 Release 构建：

```bash
scripts/install-local.sh --configuration Release --no-launch
```

生成一个用于本地测试、未 notarize 的 DMG：

```bash
scripts/build-dmg.sh
```

产物是 `dist/local/OpenTypeless-<version>.dmg` 和 SHA-256 校验文件。本地产物与正式 `dist/` 发布目录分开保存，已有产物不会被隐式覆盖，只有显式添加 `--force` 才会替换。这两个脚本不会上传 GitHub；公开分发继续使用 `scripts/release-dmg.sh` 生成 universal notarized DMG。

## 生成已公证的 DMG

公开分发需要 Apple **Developer ID Application** 证书，以及保存在 Keychain 中的 notarization 凭证。发布脚本不会自动上传 GitHub。

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
     --version 1.0.1 \
     --build 2 \
     --team-id YOURTEAMID \
     --tag v1.0.1 \
     --preflight-only
   ```
4. 生成、notarize、staple 并验证 universal DMG：
   ```bash
   scripts/release-dmg.sh \
     --version 1.0.1 \
     --build 2 \
     --team-id YOURTEAMID \
     --tag v1.0.1
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
