# Writing PastAi Extensions

[English](#english) | [中文](#中文)

## English

An extension is a folder with an `extension.json`, plus an optional script and icon.

```text
extensions/my-tool/
  extension.json
  script.js      optional
  icon.svg       optional
```

### Manifest

```json
{
  "schema": 1,
  "id": "io.github.you.my-tool",
  "version": "1.0.0",
  "name": { "en": "My Tool", "zh": "我的工具" },
  "description": { "en": "What it does.", "zh": "它的作用。" },
  "author": "You",
  "category": "search",
  "regions": ["global"],
  "icon": "symbol:magnifyingglass",
  "match": { "maxLength": 500 },
  "action": { "type": "url", "url": "https://example.com/search?q={text}" }
}
```

| Field | Notes |
|---|---|
| `id` | Lowercase reverse-DNS. `local.` is reserved for extensions on your own Mac |
| `version` | `1.0.0` form. The market offers an update when it increases |
| `name`, `description` | A string, or `{ "en": ..., "zh": ... }` |
| `regions` | `global`, `us` or `cn`, used to filter the market |
| `icon` | `symbol:<SF Symbol>`, `text:<1-2 characters>`, or `file:<path>` to a single-colour SVG or PNG |
| `match` | When to appear: `regex`, `minLength`, `maxLength`, `requiresEditable`, `apps`, `excludeApps` |
| `options` | Settings shown to the user, see below |

### Actions

| `type` | Fields | Does |
|---|---|---|
| `url` | `url`, optional `fallbackURL`, `returnKeyOption` | Opens a web address or an app's URL scheme |
| `app` | `bundleID`, `copyFirst` | Launches an app, for apps with no deep link |
| `copy` | | Copies the selection |
| `paste` | | Replaces the selection with the clipboard |
| `script` | `file` | Runs JavaScript in the sandbox |
| `ai` | `prompt`, optional `system` | Sends a prompt to the user's model and shows the result |

Templates can use `{text}`, which is percent-encoded so it cannot change the URL, and `{option.<id>}`. `{text.raw}` inserts the selection unencoded and only works for `http`, `https` and `mailto` links.

Blocked URL schemes include `file`, `javascript`, `data`, `ssh` and `shortcuts`.

### Scripts

Define `run(input)`. `input.text` is the selection, `input.options` holds the option values, and `input.language` is the app language, `en` or `zh`.

```js
function run(input) {
  return input.text.toUpperCase();
}
```

Returning a string replaces the selection. Returning an object can do more:

```js
function run(input) {
  return { show: "Shown in the popover", copy: "On the clipboard", open: "https://example.com" };
}
```

The sandbox has no network, file or process access, and scripts stop after 3 seconds.

### Options

```json
"options": [
  { "id": "phone", "type": "string", "label": { "en": "Number", "zh": "号码" }, "required": true },
  { "id": "autoSend", "type": "boolean", "label": "Send automatically", "defaultValue": "false" },
  { "id": "language", "type": "choice", "label": "Language", "defaultValue": "en",
    "choices": [{ "value": "en", "label": "English" }, { "value": "zh", "label": "中文" }] }
]
```

### Publishing

Add your folder under `extensions/`, run `python3 scripts/build-extension-index.py`, and open a pull request. `swift test` validates every extension in the catalog.

To try one locally without publishing, ask the agent to create it, or copy its folder to `~/Library/Application Support/PastAi/extensions/` with an id starting with `local.`.

## 中文

一个组件就是一个文件夹，包含 `extension.json`，以及可选的脚本和图标。

```text
extensions/my-tool/
  extension.json
  script.js      可选
  icon.svg       可选
```

### 清单

```json
{
  "schema": 1,
  "id": "io.github.you.my-tool",
  "version": "1.0.0",
  "name": { "en": "My Tool", "zh": "我的工具" },
  "description": { "en": "What it does.", "zh": "它的作用。" },
  "author": "You",
  "category": "search",
  "regions": ["cn"],
  "icon": "symbol:magnifyingglass",
  "match": { "maxLength": 500 },
  "action": { "type": "url", "url": "https://example.com/search?q={text}" }
}
```

| 字段 | 说明 |
|---|---|
| `id` | 小写的反向域名。`local.` 保留给你本机的组件 |
| `version` | `1.0.0` 格式，版本号增加时市场会提示更新 |
| `name`、`description` | 字符串，或 `{ "en": ..., "zh": ... }` |
| `regions` | `global`、`us` 或 `cn`，用于市场筛选 |
| `icon` | `symbol:<SF Symbol 名称>`、`text:<1 到 2 个字符>`，或 `file:<路径>` 指向单色 SVG 或 PNG |
| `match` | 显示条件：`regex`、`minLength`、`maxLength`、`requiresEditable`、`apps`、`excludeApps` |
| `options` | 给用户的设置项，见下文 |

### 动作

| `type` | 字段 | 作用 |
|---|---|---|
| `url` | `url`，可选 `fallbackURL`、`returnKeyOption` | 打开网址或应用的 URL Scheme |
| `app` | `bundleID`、`copyFirst` | 启动应用，用于没有深度链接的应用 |
| `copy` | | 复制选中内容 |
| `paste` | | 用剪贴板内容替换选区 |
| `script` | `file` | 在沙箱里运行 JavaScript |
| `ai` | `prompt`，可选 `system` | 把提示词发给用户的模型并显示结果 |

模板可以使用 `{text}`，它会被百分号编码，无法改变网址结构；也可以使用 `{option.<id>}`。`{text.raw}` 插入未编码的选中内容，只能用于 `http`、`https` 和 `mailto` 链接。

被禁止的协议包括 `file`、`javascript`、`data`、`ssh` 和 `shortcuts`。

### 脚本

定义 `run(input)`。`input.text` 是选中的文字，`input.options` 是设置项的值，`input.language` 是应用语言（`en` 或 `zh`）。

```js
function run(input) {
  return input.text.toUpperCase();
}
```

返回字符串表示替换选区。返回对象可以做更多：

```js
function run(input) {
  return { show: "显示在弹窗里", copy: "写入剪贴板", open: "https://example.com" };
}
```

沙箱没有网络、文件和进程访问能力，脚本运行 3 秒后会被终止。

### 设置项

```json
"options": [
  { "id": "phone", "type": "string", "label": { "en": "Number", "zh": "号码" }, "required": true },
  { "id": "autoSend", "type": "boolean", "label": "自动发送", "defaultValue": "false" },
  { "id": "language", "type": "choice", "label": "语言", "defaultValue": "zh",
    "choices": [{ "value": "en", "label": "English" }, { "value": "zh", "label": "中文" }] }
]
```

### 发布

把文件夹放进 `extensions/`，运行 `python3 scripts/build-extension-index.py`，然后提交 Pull Request。`swift test` 会校验目录里的每个组件。

想在本机试用而不发布，可以让 Agent 帮你创建；或者把文件夹复制到 `~/Library/Application Support/PastAi/extensions/`，id 以 `local.` 开头。
