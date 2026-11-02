<div align="center">

# PastAi

**Open-source AI clipboard manager and text selection toolbar for macOS**

Clipboard history for every format, a PopClip-style toolbar on any selected text, and an AI agent that can search, organize and edit everything you have copied.

[English](README.md) | [简体中文](README.zh-CN.md)

[![Release](https://img.shields.io/github/v/release/skingko/PastAi?label=download)](https://github.com/skingko/PastAi/releases/latest)
![macOS 26+](https://img.shields.io/badge/macOS-26%2B-black)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-arm64-black)
![Swift 6](https://img.shields.io/badge/Swift-6-orange)
![No dependencies](https://img.shields.io/badge/dependencies-none-brightgreen)
[![MIT License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

![PastAi clipboard panel](docs/images/panel.png)

</div>

## What it does

PastAi is an open-source, native Mac clipboard manager in the spirit of Paste, with a text selection toolbar in the spirit of PopClip, and an AI agent built into both. It is written in Swift with system frameworks only, so a small download does what several apps usually do, and nothing you copy passes through third-party code.

| | |
|---|---|
| **Clipboard history** | Text, rich text, images, video, audio, files and app-private formats, restored exactly when pasted |
| **Selection toolbar** | Select text in any app and a small bar appears at your cursor |
| **Extension market** | 30 built-in extensions for search, shopping, social, maps and AI, for US and Chinese services |
| **AI agent** | Bring your own model to search, tag, merge, rewrite and clean up your library |
| **Fast search** | Full-text search with proper Chinese support, plus OCR text inside images |
| **Private by design** | Local storage, per-board AI visibility, and approval before the agent changes anything |

## Download

Get the latest notarized build from [Releases](https://github.com/skingko/PastAi/releases/latest), open the DMG and drag PastAi to Applications.

Requires macOS 26 or later on Apple silicon.

PastAi lives in the menu bar. On first use it asks for **Accessibility** permission, which it needs to read selected text and to paste into other apps. Without the permission, history and search still work, and pasting falls back to the clipboard.

## Clipboard panel

Press `⇧⌘V` and the panel slides up from the bottom of the screen, over the Dock, without taking focus from the app you are working in.

| Key | Action |
|---|---|
| `⇧⌘V` | Open or close the panel (configurable) |
| `←` `→` | Move between cards, hold `⇧` to select several |
| `↩` / `⇧↩` | Paste / paste as plain text |
| `⌘1` to `⌘9` | Paste the Nth card |
| `Space` | Quick Look preview |
| Just type | Search |
| `⌘F` | Show filters by type, source app and date |
| `⌘←` `⌘→` or `⌘[` `⌘]` | Switch tabs |
| `⌘E` / `⌘R` | Edit / rename |
| `⌘N` | New text clip |
| `⌘J` | Send the selection to the agent |
| `⌘T` | Pause recording |
| `⌘⌫` | Delete |
| `Esc` | Clear the search, then close |

**Pinboards** keep what matters: they never expire. You can also pin built-in categories such as Images or Links as tabs in Settings. Copies from password managers are skipped, and you can exclude any app.

## Selection toolbar

Select text in any app, by dragging or double-clicking, and a toolbar appears at your cursor.

![Selection toolbar](docs/images/selection-bar.png)

Four extensions are on by default:

- **Copy**
- **Translate** runs through your AI model and streams into a small popover. The result is added to your clipboard, ready to paste anywhere, and **Insert** replaces the original text in place.
- **Google** searches the web.
- **WhatsApp** sends the selection to a contact you choose, and can press send for you.

![Translate popover](docs/images/translate.png)

The toolbar never takes focus, which is why Insert can replace your selection directly. Extensions only appear when they apply: Open Link only shows for a URL, and Paste only in editable text.

## Extensions

Open **Settings > Extensions** to reorder the toolbar, configure each extension and browse the market. The market is the [`extensions`](extensions) folder of this repository, fetched straight from GitHub, with a copy inside the app so it works offline.

![Extension settings](docs/images/extensions.png)

| Category | Extensions |
|---|---|
| Text | Copy, Paste, Change Case, Word Count, Open Link |
| AI | Translate, Summarize, Polish, Explain, ChatGPT |
| US services | Google, Google Maps, Wikipedia, YouTube, Amazon, Reddit, X, GitHub, WhatsApp, Gmail |
| China services | Baidu, Zhihu, Weibo, Bilibili, Taobao, JD.com, Xiaohongshu, Douban, Amap, WeChat |

Every extension follows one manifest format, with six action types: open a URL or app link, launch an app, copy, paste, run sandboxed JavaScript, or call your AI model. See [docs/EXTENSIONS.md](docs/EXTENSIONS.md) to write your own.

**Or ask the agent.** Describe what you want, for example "add a button that turns a URL into a Markdown link", and the agent writes the extension, tests it on sample text, and installs it after you approve.

There is deliberately no shell or AppleScript action. Extensions are downloaded code, so they can only open links and apps, call your model, or compute in a JavaScript sandbox with no network or file access. Each script runs in its own process and is killed if it hangs.

## AI agent

![Main window with the agent](docs/images/workspace.png)

Open the main window and ask for what you want:

- "Sort this week's links into pinboards by topic"
- "Find the nginx config I copied last month"
- "Merge these five clips into clean Markdown"
- "Turn the table in this screenshot into CSV"
- "Clear out duplicates and old screenshots"

Add a provider in **Settings > AI Models**. PastAi speaks the OpenAI-compatible protocol, which covers OpenAI, Google Gemini, DeepSeek, Qwen, Kimi, GLM, OpenRouter, Ollama and LM Studio, plus the native Anthropic API. Keys are stored in the macOS Keychain.

With Ollama or LM Studio, nothing leaves your Mac.

## Privacy and safety

These rules are enforced in code rather than by asking the model nicely:

- **Local by default.** Your library stays in `~/Library/Application Support/PastAi`.
- **Hidden means hidden.** Hide a clip or a whole pinboard from AI and it is filtered out in the database query, so the agent cannot read it even by ID. Text that looks like a credential is hidden automatically.
- **Approval.** Reading is automatic. Changing or deleting content, and installing an extension, always needs your confirmation, and "allow for this conversation" never covers those.
- **Undo.** Everything the agent changes in a run can be undone in one click.
- **Clipboard text is data.** Copied content cannot instruct the agent, and the agent has no network, file or shell tools, so your content only ever goes to the model you configured.
- **Consent.** The first time content would go to a cloud provider, PastAi asks.

## Build from source

Xcode is not needed beyond its command line tools.

```bash
git clone https://github.com/skingko/PastAi.git
cd PastAi
./scripts/build.sh debug     # or release
swift test
```

The app is written to `~/Library/Caches/PastAi/dist/PastAi.app`. With a Developer ID certificate in your keychain it is signed automatically; otherwise it is signed ad hoc, and macOS asks for Accessibility again after each build.

`scripts/release.sh` builds a signed, notarized DMG in `dist/`.

### Architecture

```text
App/                 Composition root: menu bar, hotkey, lifecycle
Sources/
  ClipCore/          Capture, storage, search, paste. No UI, no AI
  ClipEnrich/        Thumbnails, media metadata, OCR
  ClipExtensions/    Manifests, validation, JavaScript sandbox, market
  QuickPanel/        The clipboard panel
  SelectionBar/      The selection toolbar and result popover
  ClipAgent/         Model clients, tools, approvals, agent loop
  Workspace/         Main window, chat and settings
extensions/          The extension market
```

`QuickPanel` and `SelectionBar` link no AI code, so copy and paste keep working if a model is misconfigured. All changes to the library go through one code path and one undo log, for people and for the agent alike.

## Contributing

New extensions are the easiest way to help: add a folder under [`extensions`](extensions), run `python3 scripts/build-extension-index.py`, and open a pull request. It appears in everyone's market as soon as it merges.

## License

PastAi is released under the [MIT License](LICENSE).

Brand icons in `extensions` come from [Simple Icons](https://github.com/simple-icons/simple-icons) (CC0). The logos remain trademarks of their owners, and the license above does not grant any rights to them.

---

Open source clipboard manager for Mac, Paste alternative, PopClip alternative, macOS text selection toolbar, AI translation on selected text, clipboard history with OCR, AI agent for macOS, Ollama and local LLM clipboard tool.
