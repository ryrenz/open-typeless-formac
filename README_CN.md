# open-typeless-formac

[English](README.md) | [中文](README_CN.md)

一个开源的 macOS 菜单栏语音转文字工具。按下快捷键开始录音，再按一下停止——语音自动转写并插入到当前输入框中。

灵感来源于 [Typeless](https://www.typeless.com/)。

## 功能

- **按键切换录音**：按一下开始录音，再按一下停止（不需要一直按着）
- **自动插入**：转写文字通过 Cmd+V 自动粘贴到当前输入框
- **弹窗兜底**：如果没有聚焦的输入框，弹出浮窗显示结果并提供复制按钮
- **进度浮窗**：屏幕底部居中显示录音/转写状态和实时音量
- **双击取消**：快速按两下快捷键取消录音
- **多模型可选**：支持 gpt-4o-mini-transcribe、gpt-4o-transcribe、whisper-1
- **自定义 API**：兼容任何 OpenAI 兼容端点（Groq、Together AI 等）
- **中英文界面**：设置中可切换界面语言

## 快速开始

### 1. 编译运行

1. 从 [App Store](https://apps.apple.com/app/xcode/id497799835) 下载 **Xcode**（需要 macOS 14.0+）
2. 克隆本仓库：
   ```bash
   git clone https://github.com/scinttt/open-typeless-formac.git
   ```
3. 用 Xcode 打开 `OpenTypeless.xcodeproj`
4. 按 **Cmd+R** 编译运行

### 2. 找到应用

编译运行后，在屏幕**右上角菜单栏**找到 **麦克风图标（🎙）**——这就是 open-typeless。点击它可以进入设置。

### 3. 授权权限

首次启动时会提示授权：
- **麦克风** — 用于录音
- **辅助功能** — 用于全局快捷键和文字插入

> 每次重新编译后，需要重新授权辅助功能：前往系统设置 > 隐私与安全性 > 辅助功能，用减号（-）删掉旧条目，然后在 app 中点击"授权"重新添加。

### 4. 配置 API Key

点击菜单栏图标 → **Settings** → 进入 **API** 标签页：
- **Provider**：选择 "OpenAI" 或 "Custom"（用于 OpenAI 兼容端点）
- **API Key**：输入你的 OpenAI API key（`sk-...`）
- **Model**：选择转写模型（默认：`gpt-4o-mini-transcribe`）

OpenAI API key 获取地址：[platform.openai.com/api-keys](https://platform.openai.com/api-keys)

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
| 文字插入 | 剪贴板 + 模拟 Cmd+V |
| 全局快捷键 | CGEvent tap（切换模式，支持单修饰键） |

## 常见问题

| 问题 | 解决方案 |
|------|---------|
| 快捷键不工作 | 检查辅助功能权限；在系统设置中删掉旧条目重新添加 |
| "API key not configured" | 在设置 → API 标签页中输入 API key |
| 没有音频输入 | 检查系统设置 > 声音 > 输入，确保选择了麦克风 |
| 文字没有插入 | 停止录音前先点击目标输入框 |
| 找不到应用 | 看右上角菜单栏的麦克风图标 |

## 许可证

MIT
