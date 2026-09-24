# Nib Plugin API (v1)

A Nib plugin is JavaScript that runs inside the app (JavaScriptCore). It can do **what a user can do by hand**, because it calls the same command registry the UI uses — reading, adding, editing and deleting anything in any document or in the library — within the permissions the user granted and the exceptions listed in FEATURES.md › "Exceptions to the modify-anything guarantee" (security settings, secrets, installing plugins, locked documents, system UI that needs a person). On top of that, a plugin can add toolbar buttons, menu items, canvas tools and their option bars, tap handlers and canvas decorations, panels, templates and covers, commands, command hooks, settings, key bindings, AI actions, file importers/exporters, new item types, text-document blocks, stroke processors, Pencil actions and content packs (stickers, tape patterns, whiteboard templates).

Every command a plugin registers also becomes available to the in-app AI and to external agents over the MCP bridge, unless the plugin opts out (`ai: false` / `bridge: false`; the user can override opt-outs with Settings › Plugins › "Expose hidden plugin commands").

Implementation owners:

| Part | Feature |
|---|---|
| Runtime | F077 |
| Host and contributions | F078 |
| Install and trust | F079 |
| Manager, gallery and console | F080 |
| HTML panels | F081 |
| Examples | F082 |

The Swift types these map to (`PluginManifest`, registries, `CommandDescriptor`) are in CONTRACTS.md.

---

## 1. Package

```
dev.example.cards.nibplugin        ← a zip (or a plain folder)
├── manifest.json
├── main.js                        ← ONE bundled script (esbuild/rollup IIFE); no module loader
├── panels/stats.html              ← optional HTML panels (+ their js/css/images)
├── templates/cornell.pdf          ← optional
└── assets/…
```

The installed copy lives in `<Library>/.nib-library/plugins/<id>/`, so it syncs with the library. The permission grant is **device-local** and bound to the sha256 of that package folder (sorted relative paths + file contents). A plugin that arrives through a synced folder, or changes on disk, stays disabled until the user reviews it on this device. Plugin data (`nib.storage`) lives outside the hashed folder, in `<Library>/.nib-library/plugin-data/<id>/storage.<device>.json` (merged per key across devices), so storing data never invalidates the grant.

Limits:

- Bundle ≤ 20 MB.
- `nib.storage` ≤ 5 MB.
- One call ≤ 30 s, or ≤ 300 s with `longRunning`.
- Nested command depth ≤ 16.

## 2. Manifest

```json
{
  "id": "dev.example.cards",
  "name": "Selection → Flashcards",
  "version": "1.2.0",
  "api": 1,
  "author": "Ada",
  "description": "Turns 'term — definition' lines into a study set.",
  "homepage": "https://github.com/ada/nib-cards",
  "entry": "main.js",
  "permissions": ["document:read", "library:write", "ai"],
  "network": { "hosts": [] },
  "contributes": {
    "commands": [ … ], "menus": [ … ], "toolbar": [ … ], "tools": [ … ], "toolOptions": [ … ], "panels": [ … ],
    "templates": [ … ], "keybindings": [ … ], "settings": { … }, "aiActions": [ … ],
    "ai": { "instructions": "…" }, "importers": [ … ], "exporters": [ … ], "itemTypes": [ … ],
    "tapHandlers": [ … ], "blocks": [ … ], "strokeProcessors": [ … ], "pencilActions": [ … ], "commandHooks": [ … ],
    "elements": [ … ], "tapePatterns": [ … ], "boardTemplates": [ … ]
  }
}
```

| Field | Rules |
|---|---|
| `id` | Reverse-DNS, `[a-z0-9.-]`, unique. It owns everything the plugin registers. |
| `version` | semver. An update with more permissions asks for consent again. |
| `api` | `1`. |
| `entry` | Path of the JS bundle. It is evaluated once, when the plugin starts. |
| `permissions` | Scopes (§3). Anything not listed is denied at call time with `permission_denied`. |
| `network.hosts` | Hostnames allowed for `nib.net.fetch` and panels. Only honoured with `"network"`. |
| `contributes` | §5. Every field is optional. |

## 3. Permissions

| Permission | Allows | Consent text |
|---|---|---|
| `document:read` | Reading documents (query/search/render/recognize) | "Read your notes" |
| `document:write` | Editing documents (ink, items, pages, text…) | "Change your notes" |
| `library:read` | Listing folders and documents | "See your library" |
| `library:write` | Creating, moving, renaming and trashing documents and folders; installing elements and templates | "Organise your library" |
| `destructive` | Deleting, overwriting and clearing | "Delete content" |
| `app` | Session and app commands (tool selection, panels, settings, view) | "Control the app" |
| `ai` | `nib.ai.complete`, using the user's AI provider and costing their tokens | "Use your AI provider" |
| `network` | `nib.net.fetch` and panel requests to `network.hosts` | "Connect to: host1, host2" |

`plugins:manage` (install, enable and remove plugins) and `security` (passwords, keys, grants, bridge, confirmation policies) are **never** granted to plugins. Irreversible commands always ask the user, even when a plugin holds `destructive`.

## 4. JavaScript API

Everything goes through one native bridge. Values cross it as JSON. Calls return Promises and reject with `{code, message, path?, hint?}` (codes as in ARCHITECTURE.md §17). Generate exact, typed definitions for every current command with `plugin.sdkTypes` (Settings › Plugins › Developer › Export nib.d.ts).

```ts
declare namespace nib {
  /** This plugin. `settings` = current values of contributes.settings. */
  const plugin: { id: string; version: string; settings: Record<string, unknown> };

  /** Passed to every handler. Calls made through ctx.execute share the caller's undo group (one Undo step). */
  interface CallContext {
    group: string;                 // undo group of this invocation
    principal: string;             // "plugin:<id>"
    /** True in ask mode and inside commands declared "read": every execute must then be a read command. */
    readOnly: boolean;
    execute<T = any>(command: string, params?: object, opts?: { dryRun?: boolean }): Promise<T>;
  }

  namespace commands {
    /** Run any command (built-in, feature or another plugin's). A fresh undo group unless called via ctx. */
    function execute<T = any>(command: string, params?: object, opts?: { dryRun?: boolean; group?: string }): Promise<T>;
    /** Several commands in order as ONE undo step (commands.batch). */
    function batch(calls: { command: string; params?: object }[], opts?: { stopOnError?: boolean }):
      Promise<{ ok: boolean; value?: any; error?: NibError }[]>;
    /** Implement a command declared in manifest.contributes.commands. */
    function register(id: string, handler: (params: any, ctx: CallContext) => unknown | Promise<unknown>): void;
    function list(namespace?: string): Promise<{ id: string; title: string; summary: string; effect: string; destructive: boolean }[]>;
    function describe(id: string): Promise<{ id: string; params: object; examples: object[]; effect: string; scopes: string[] }>;
  }

  /** Sugar over the read commands (query.*, search.text, recognize.*, render.page). */
  namespace query {
    function context(): Promise<Context>;                          // current document, page, selection, tool
    function tree(root?: string, depth?: number): Promise<any>;    // library
    function get(ref: string, opts?: { depth?: number; points?: boolean; fields?: string[] }): Promise<any>;
    function find(filter: { in: string; kinds?: string[]; layer?: number; bbox?: number[];
                            where?: object; text?: string; limit?: number; cursor?: string }): Promise<{ items: any[]; cursor?: string }>;
    function search(text: string, scope?: string): Promise<any[]>;
    function pageText(page: string): Promise<{ blocks: { text: string; bbox: number[]; source: string; itemIDs: string[] }[] }>;
    /** render.page: a temporary PNG ("tmp:<name>", long edge ≤ 1568 px); marks number the items. */
    function render(page: string, opts?: { scale?: number; region?: number[]; marks?: boolean }):
      Promise<{ asset: string; pxPerPt: number; region: number[]; marks?: Record<string, string> }>;
  }

  namespace canvas {
    /** Transient overlay on a page (canvas.decorate): a DisplayList in page coordinates, removed after ttl seconds
     *  (default 5) or with clear(). Use it for highlights, previews and hints; nothing is written to the document. */
    function decorate(page: string, display: { ops: object[] }, opts?: { id?: string; ttl?: number }): Promise<string>;
    function clear(id?: string): Promise<void>;
  }

  namespace events {
    /** Subscribe; returns an unsubscribe function. Deliveries are coalesced (≤ 1 per 100 ms per type);
     *  events caused by this plugin are skipped unless filter.self is true. */
    function on(type: string, fn: (e: NibEvent, ctx: CallContext) => void,
                filter?: { doc?: string; self?: boolean }): () => void;
  }

  namespace ui {
    function toast(message: string): void;
    function confirm(title: string, message?: string): Promise<boolean>;
    function prompt(title: string, placeholder?: string, initial?: string): Promise<string | null>;
    function choose(title: string, options: string[]): Promise<number | null>;
    function openPanel(id: string): Promise<void>;             // one of contributes.panels
    function postToPanel(id: string, message: unknown): void;  // → window.nib.onMessage in the panel
  }

  namespace storage {                                           // per plugin, JSON values, ≤ 5 MB, syncs with the library (outside the hashed folder)
    function get<T = unknown>(key: string): Promise<T | undefined>;
    function set(key: string, value: unknown): Promise<void>;
    function remove(key: string): Promise<void>;
    function keys(): Promise<string[]>;
  }

  namespace settings {                                          // any setting; "plugin.<id>.*" = this plugin's own
    function get<T = unknown>(name: string): Promise<T | undefined>;
    function set(name: string, value: unknown): Promise<void>;   // "security.*" → permission_denied
  }

  namespace assets {
    /** Store bytes in a document; returns an AssetRef name for image/pdf/tape items. `url` must be https or a tmp: ref. */
    function put(doc: string, data: { base64?: string; url?: string; text?: string }, ext: string): Promise<string>;
    /** asset.upload: a temporary asset ("tmp:<name>", 1 h) that every url-taking command accepts (import.files, image.insert…). */
    function upload(data: { base64?: string; text?: string }, ext: string): Promise<string>;
    function url(doc: string, asset: string): Promise<string>;
  }

  namespace ai {                                                // needs "ai"; tool calls run as this plugin
    function complete(req: { system?: string; messages: { role: "user" | "assistant"; text: string; images?: string[] }[];
                             tools?: string[] /* command ids; [] = none */; mode?: "ask" | "edit"; maxSteps?: number;
                             json?: boolean }): Promise<{ text: string; group?: string; changes: ChangeSummary }>;
  }

  namespace net {                                               // needs "network" + host in manifest.network.hosts
    function fetch(url: string, init?: { method?: string; headers?: Record<string, string>; body?: string; bodyBase64?: string }):
      Promise<{ status: number; headers: Record<string, string>; text: string; base64?: string }>;
  }

  interface NibEvent { seq: number; type: string; at: number; principal?: string; doc?: string;
                       changes?: ChangeSummary; payload?: any }
  interface ChangeSummary { created: string[]; updated: string[]; removed: string[] }
  interface NibError { code: string; message: string; path?: string; hint?: string }
}
// Globals: console.log/warn/error (→ plugin logs), setTimeout/clearTimeout/setInterval/clearInterval,
// structuredClone (JSON), TextEncoder/TextDecoder, atob/btoa. No fetch, XMLHttpRequest, require or file system:
// commands take tmp: refs (nib.assets.upload) or https URLs, never file:// paths, and exports return tmp: assets.
```

The data shapes are the same JSON used everywhere, as defined in CONTRACTS.md and ARCHITECTURE.md §5 and §7:

- **Refs:** `"page:D/P"`, `"item:D/P/I"`.
- **Items:** `{kind, stroke|shape|…}`.
- **Strokes:** `{"style": {...}, "fmt": "xy", "pts": [x, y, x, y, …]}`.
- **Colours:** `"#RRGGBBAA"`.
- **Points and rects:** `[x,y]` and `[x,y,w,h]` in page points, with the origin at the top left.
- **Rich text:** a string or `{paragraphs:[…]}`.

## 5. Contribution points

### 5.1 Commands

```json
"commands": [{
  "id": "dev.example.cards.fromSelection",
  "title": "Make Flashcards",
  "summary": "Turn 'term — definition' lines in the current selection into a new study set.",
  "params": { "type": "object", "properties": { "separator": { "type": "string" } } },
  "examples": [ { "separator": "—" } ],
  "effect": "library", "target": "library", "destructive": false,
  "ai": true, "aiDirect": true, "bridge": true, "longRunning": false
}]
```

- **Id.** It must start with `<pluginId>.`.
- **Effect.** `read | session | edit | library | irreversible`, default `edit`. **Target:** `document | library | app`. Together with `destructive` these decide the scopes the command needs, and which confirmations the AI and bridge show. A command declared `read` runs **read-only**: anything its handler executes must be a read command, or the call fails with `permission_denied` (so an honest label is enforced, not trusted). When the AI or the bridge runs your command, their confirmation policy carries into your handler's calls.
- **Exposure.** `ai: false` or `bridge: false` hides the command from those callers (the user can override this in Settings › Plugins). `aiDirect: true` gives the command its own AI tool, not only access via `nib_run`.
- **Creating commands** should accept an optional `id`/`ids` param for the records they create, like built-in ones.
- **Summary.** One line, written for an LLM.
- **Examples.** Give at least one when the command is exposed to AI.
- **Handler.** Register it with `nib.commands.register(id, handler)` in `main.js`. Everything the handler does through `ctx.execute` lands in one undo step.

### 5.2 Menus

```json
"menus": [{ "location": "objectMenu", "command": "dev.example.cards.fromSelection", "title": "Flashcards",
            "icon": "rectangle.stack", "when": { "selectionKinds": ["stroke", "text"], "minSelection": 1, "docKinds": ["notebook"] } }]
```

Valid locations are the raw values of `MenuLocation`: `objectMenu`, `pageLongPress`, `documentMore`, `documentTitle`, `addPage`, `shareExport`, `libraryItem`, `libraryNew`, `librarySelection`, `appMenu`, `sidebarPage`, `sidebarSelection`, `textSelection`, `audioClip`, `block`, `card`, `board`, `outlineEntry`, `comment`, `transcriptSegment`, `tab`.

The command receives the menu context as params, and fields you pass explicitly are kept:

```json
{ "doc": "doc:D", "page": "page:D/P", "point": [x, y], "selection": ["item:…"], "nodes": ["…"], "ref": "block:D/B", "index": 3 }
```

### 5.3 Toolbar

```json
"toolbar": [{ "id": "dev.example.cards.button", "title": "Cards", "icon": "rectangle.stack",
              "group": "accessories", "command": "dev.example.cards.fromSelection" }]
```

- An entry sets either `command` or `tool` (the id of a `tools` entry).
- Plugin buttons appear in Toolbar Customization like built-in ones, and users can hide or reorder them.

### 5.4 Canvas tools

JavaScript never runs per Pencil sample. The host captures the input and draws a preview, then calls your command once:

```json
"tools": [{ "id": "dev.example.translate.tool", "title": "Translate Ink", "icon": "character.bubble",
            "input": "stroke", "preview": "lasso", "sticky": false, "command": "dev.example.translate.onInput" }]
```

| `input` | Params your command receives | Host preview |
|---|---|---|
| `stroke` | `{page, pts:[x,y,…], fmt:"xy", bbox}` on lift | `ink` \| `lasso` \| `none` |
| `tap` | `{page, point}` | none |
| `rect` | `{page, rect}` | dashed rectangle |

**Tool options.** `"toolOptions": [{ "tool": "dev.example.translate.tool", "settings": ["targetLanguage", "keepInk"] }]` shows an options bar for your tool: a form over those keys of `contributes.settings`.

### 5.5 Panels (HTML)

```json
"panels": [{ "id": "dev.example.stats.panel", "title": "Word Count", "icon": "chart.bar",
             "entry": "panels/stats.html", "placement": "floating" }]
```

- **Placement:** `sidebarTab`, `floating`, `sheet` or `libraryTab`.
- **Hosting.** The panel is a WKWebView loaded from `nib-plugin://<id>/panels/stats.html`, and it can only read its own plugin's files.
- **API.** The panel gets the same `window.nib` API with the plugin's permissions, plus:
  - `nib.onMessage(fn)` receives what `main.js` sends with `nib.ui.postToPanel`.
  - `nib.postMessage(msg)` delivers a `plugin.message` event to `main.js`.
- **Network.** Loads to any `http(s)` host outside `network.hosts` are blocked.

### 5.6 Templates

```json
"templates": [{
  "id": "dev.example.planner.weekly", "title": "Weekly Planner", "category": "Planners", "kind": "spec",
  "size": { "width": 595.28, "height": 841.89 },
  "params": { "accent": { "type": "color", "default": "#3A7BD5FF" }, "startMonday": { "type": "bool", "default": true } },
  "spec": { "paper": "#FFFFFFFF", "ops": [
    { "op": "rect",   "rect": [36, 36, 523.28, 60], "fill": "$accent", "radius": 8 },
    { "op": "text",   "rect": [52, 52, 400, 30], "text": "Week of ____", "fontSize": 20, "stroke": "#FFFFFFFF" },
    { "op": "hlines", "rect": [36, 120, 523.28, 690], "spacing": 98.5, "stroke": "#C8D0DAFF", "width": 0.75 }
  ] }
}]
```

- **Ops.** `op` is one of `rect`, `ellipse`, `line`, `polyline`, `polygon`, `text`, `image`, `hlines`, `vlines` or `dots`. The other fields match `DisplayOp`: `rect`, `points`, `stroke`, `fill`, `width`, `dash`, `text`, `fontSize`, `fontName`, `asset`, `spacing` and `radius`.
- **Parameters.** A string `"$name"` anywhere in `spec` is replaced by that parameter's value.
- **PDF templates.** `kind: "pdf"` with `"file": "templates/x.pdf"` uses the first page.
- **Covers.** `"isCover": true` lists the template under Covers (page 1) instead of Papers.
- **Uninstalling.** Pages keep rendering after the plugin is uninstalled, because the resolved spec or PDF is copied into the document.

### 5.7 Keybindings, settings and AI

- **Keybindings:**

  ```json
  "keybindings": [{ "key": "cmd+shift+f", "command": "dev.example.cards.fromSelection", "title": "Make Flashcards" }]
  ```

  Modifiers are `cmd`, `shift`, `alt`/`option` and `ctrl`. They appear in the ⌘-hold overlay.
- **Settings.** A JSON Schema object whose properties become an auto-generated settings page. Values are stored as `plugin.<id>.<key>` and exposed as `nib.plugin.settings`.
- **AI actions.** `"aiActions": [{ "title": "Quiz me", "prompt": "…", "scope": "selection", "mode": "edit", "icon": "questionmark.bubble" }]` adds a chip in the AI panel.
- **AI instructions.** `"ai": { "instructions": "Prefer dev.example.cards.fromSelection when the user asks for flashcards." }` is appended to the AI system prompt while the plugin is enabled. The limit is 1,000 characters.

### 5.8 Importers, exporters and item types

- **Importers:**

  ```json
  "importers": [{ "extensions": ["apkg"], "command": "dev.example.anki.import", "title": "Anki deck" }]
  ```

  The command receives `{asset, name, target:{folder?, doc?, position?}}`, where `asset` is a temporary asset. It creates the documents and returns their refs.
- **Exporters.** `"exporters"` works the same way: the command receives `{docs, pages?, options}` and returns `{files:[{name, base64}]}`.
- **Item types.**

  ```json
  "itemTypes": [{ "type": "chart", "title": "Chart", "edit": "dev.example.chart.edit" }]
  ```

  These are `custom` items (`{owner: "<pluginId>", type, frame, data, display}`). The host always draws `display` (a DisplayList relative to `frame`), so the items survive uninstall. Double-tapping one calls `edit` with `{ref}`. Update `data` and `display` together with `item.update`. Optional fields:
  - `"inspector"`: a JSON Schema over `data` fields; selecting the item shows it as a style inspector whose changes go through `item.update`.
  - `"textPath"`: a dot path inside `data` (e.g. `"title"`) whose text is indexed by search, returned by `recognize.pageText` / `nib_page_text` and read by VoiceOver.

### 5.9 Tap handlers, blocks, stroke processors, Pencil actions, command hooks

- **Tap handlers.** `"tapHandlers": [{ "gesture": "tap" | "doubleTap" | "longPress", "command": "…", "itemKinds": ["stroke"], "itemTypes": ["chart"] }]`. Finger gestures on the canvas are offered to your command (with `{page, point, ref?, gesture}`) before the active tool; return `{ "handled": true }` to consume it. Pair with `nib.canvas.decorate` for hover-free UI such as underlines or badges.
- **Blocks.** `"blocks": [{ "type": "chart", "title": "Chart", "icon": "chart.bar", "height": 160, "command": "…", "aliases": ["graph"] }]` adds a text-document block kind to the slash and Turn Into menus. Blocks are `BlockKind.custom` with `{owner, type, height, data, display}`; the editor draws `display`, and your `command` is called with `{doc, after?}` to insert and with `{ref}` when tapped.
- **Stroke processors.** `"strokeProcessors": [{ "id": "…", "command": "…", "tools": ["pen"] }]`: your command runs once per finished stroke with `{page, stroke}` and returns `{stroke}` (changed) or `{drop: true}`. Budget 50 ms; on timeout or error the raw stroke is kept.
- **Pencil actions.** `"pencilActions": [{ "gesture": "doubleTap" | "squeeze", "command": "…", "title": "…" }]` appear as choices in Settings › Apple Pencil.
- **Command hooks.** `"commandHooks": [{ "commands": ["page.add", "export.*"], "command": "…" }]`: before each matching call (from anyone), your command (effect must be `read`) gets `{command, params}` and returns `{}` to let it pass, `{params: …}` to change the params, or throws to veto it.

### 5.10 Content packs

A content pack is a plugin that contributes only content (manifest `kind: "content"` in the gallery):

- `"templates"`: papers, planners and covers (`isCover`).
- `"elements": [{ "id": "…", "title": "Arrows", "files": ["elements/arrows.json"] }]`: sticker collections; each file is a clipboard fragment (`{format: "nib-fragment/1", items, assets, bounds}`) or an array of `{id, title, fragment}`.
- `"tapePatterns": [{ "id": "…", "title": "Stripes", "file": "tape/stripes.png" }]`: ~100 px PNG tiles.
- `"boardTemplates": [{ "id": "…", "title": "Retro", "diagram": { "nodes": […], "edges": […], "layout": "tree" } }]` (a `diagram.create` spec without `page`) or `"file"` (a fragment): whiteboard frameworks for `board.insertTemplate`.

## 6. Events

| Type | When | Payload |
|---|---|---|
| `tx.committed` | Any committed change, including undo/redo and sync merges (principal `sync:*`) | `changes` (refs), `doc`, `principal` |
| `doc.opened` / `doc.closed` | A document is loaded into or evicted from memory | `doc` |
| `session.document` | A window shows another document | `payload.session` |
| `page.changed` | The current page changed | `doc`, `payload.session` |
| `tool.changed` | The active tool changed | `payload.session` |
| `selection.changed` | The selection changed | `payload.session` (read it with `query.context`) |
| `library.changed` | Library structure changed | — |
| `ai.turn.finished` | An AI turn ended | `payload.group`, `changes` |
| `plugin.message` | A panel posted a message | `payload` |
| `sync.status` | The sync engine's state changed | `payload` |
| `laser.moved` | Laser pointer moved | `payload {page, point, mode}` |

Events carry refs, not content. Query what you need.

## 7. Undo, provenance, dry runs

- **Undo.** One plugin invocation (a command handler, a menu action, an event callback) is **one undo step** when you use `ctx.execute`, or `nib.commands.batch` outside a ctx.
- **Read-only calls.** In ask mode, and inside commands you declared `read`, `ctx.readOnly` is true and only read commands succeed.
- **Provenance.** Items a plugin creates get `createdBy: "plugin:<id>"`, stamped by the host (a `createdBy` you pass is ignored, and it cannot be changed later). The user can select them and see who made what in the History panel.
- **Dry runs.** `{dryRun: true}` runs a command, reports `changes`, then rolls back. Use it to preview or test.

## 8. Distribution: gallery index

A gallery is any JSON file you host, for example raw on GitHub. Users add its URL in Settings › Plugins › Galleries. The default index is `plugins/index.json` in the Nib repo.

```json
{ "version": 1, "name": "Nib Community",
  "plugins": [{ "id": "dev.example.cards", "name": "Selection → Flashcards", "version": "1.2.0",
                "description": "…", "author": "Ada", "category": "Study", "kind": "plugin",
                "url": "https://example.com/dev.example.cards-1.2.0.nibplugin",
                "sha256": "9c1e…", "permissions": ["document:read", "library:write", "ai"], "minApi": 1,
                "screenshots": ["https://…/1.png"] }] }
```

- **Kind.** `kind` is `plugin` or `content`. Content packs are plugins that contribute only templates, covers, elements, tape patterns or board templates (§5.10); this is Nib's stand-in for Goodnotes' Marketplace.
- **Source.** Either `url` (a `.nibplugin`/zip) or `base` + `files`: a folder of raw files, `base` relative to the index URL (e.g. `"base": "examples/hello-world/", "files": ["manifest.json", "main.js"]`), so a Git repo can serve plugins without building archives.
- **Integrity.** `sha256` is the installer's folder hash — sha256 over the sorted relative paths and contents of the unpacked files — so it is the same whether the plugin comes as a zip or as raw files. It is verified before install.

## 9. AI-authored plugins

The in-app AI and bridge agents can write plugins for the user:

1. Call `plugin.docs` (this reference) and `plugin.sdkTypes` (the live `nib.d.ts`).
2. Call `plugin.install {files: {"manifest.json": "…", "main.js": "…"}}`. This **always** opens the consent sheet, which includes a code viewer.
3. Iterate with `commands.execute {dryRun: true}`, `plugin.logs {id}` and `plugin.reload {id}`.

Plugins themselves can never install plugins.

## 10. Examples

These ship in `plugins/examples/` (F082) and double as CI fixtures.

### 10.1 hello-world: toolbar button, command and toast

`manifest.json`

```json
{ "id": "dev.nib.hello", "name": "Hello", "version": "1.0.0", "api": 1, "entry": "main.js",
  "permissions": ["document:write"],
  "contributes": {
    "commands": [{ "id": "dev.nib.hello.stamp", "title": "Stamp Hello",
                   "summary": "Write 'Hello from a plugin' as a text box at the top of the current page.",
                   "examples": [{}], "effect": "edit" }],
    "toolbar": [{ "id": "dev.nib.hello.button", "title": "Hello", "icon": "hand.wave", "command": "dev.nib.hello.stamp" }]
  } }
```

`main.js`

```js
nib.commands.register("dev.nib.hello.stamp", async (params, ctx) => {
  const c = await ctx.execute("query.context");
  if (!c.page) return nib.ui.toast("Open a page first");
  const r = await ctx.execute("text.createBox", {
    page: c.page.ref, frame: { x: 48, y: 48, w: 320, h: 40 },
    text: "Hello from a plugin 👋"
  });
  nib.ui.toast("Stamped " + r.ref);
  return r;
});
```

### 10.2 flashcards-from-selection: object menu, AI tool and library write

`manifest.json`

```json
{ "id": "dev.nib.cards", "name": "Selection → Flashcards", "version": "1.0.0", "api": 1, "entry": "main.js",
  "permissions": ["document:read", "library:write"],
  "contributes": {
    "commands": [{ "id": "dev.nib.cards.fromSelection", "title": "Make Flashcards",
      "summary": "Create a study set from 'term — definition' lines in the selected handwriting or text.",
      "params": { "type": "object", "properties": { "separator": { "type": "string" } } },
      "examples": [{ "separator": "—" }], "effect": "library", "target": "library", "aiDirect": true }],
    "menus": [{ "location": "objectMenu", "command": "dev.nib.cards.fromSelection", "title": "Flashcards",
                "icon": "rectangle.stack", "when": { "minSelection": 1 } }],
    "settings": { "type": "object", "properties": { "separator": { "type": "string", "default": "—" } } },
    "ai": { "instructions": "When the user asks to turn notes into flashcards, call dev.nib.cards.fromSelection." }
  } }
```

`main.js`

```js
nib.commands.register("dev.nib.cards.fromSelection", async (p, ctx) => {
  const c = await ctx.execute("query.context");
  const refs = c.selection?.refs ?? [];
  if (!refs.length) throw { code: "invalid_params", message: "Select some notes first" };
  const sep = p.separator || nib.plugin.settings.separator || "—";
  const { text } = await ctx.execute("recognize.items", { refs });
  const pairs = text.split("\n").filter(l => l.includes(sep))
                    .map(l => l.split(sep).map(s => s.trim())).filter(([q, a]) => q && a);
  const set = await ctx.execute("doc.create", { kind: "studySet", title: `${c.document.title} — cards` });
  await ctx.execute("commands.batch", { calls: pairs.map(([q, a]) => ({
    command: "card.add", params: { doc: set.ref, front: { text: q }, back: { text: a } } })) });
  nib.ui.toast(`Made ${pairs.length} cards`);
  return { set: set.ref, cards: pairs.length };
});
```

### 10.3 word-count: HTML panel and events

`manifest.json`

```json
{ "id": "dev.nib.wordcount", "name": "Word Count", "version": "1.0.0", "api": 1, "entry": "main.js",
  "permissions": ["document:read"],
  "contributes": {
    "panels": [{ "id": "dev.nib.wordcount.panel", "title": "Word Count", "icon": "textformat.123",
                 "entry": "panel.html", "placement": "floating" }],
    "toolbar": [{ "id": "dev.nib.wordcount.open", "title": "Word Count", "icon": "textformat.123",
                  "command": "dev.nib.wordcount.show" }],
    "commands": [{ "id": "dev.nib.wordcount.show", "title": "Show Word Count",
                   "summary": "Open the word count panel for the current page.", "examples": [{}], "effect": "session", "target": "app" }]
  } }
```

`main.js`

```js
async function countCurrentPage() {
  const c = await nib.query.context();
  if (!c.page) return { words: 0 };
  const { blocks } = await nib.query.pageText(c.page.ref);
  const words = blocks.map(b => b.text).join(" ").split(/\s+/).filter(Boolean).length;
  return { page: c.page.index + 1, words };
}
nib.commands.register("dev.nib.wordcount.show", async () => {
  await nib.ui.openPanel("dev.nib.wordcount.panel");
  nib.ui.postToPanel("dev.nib.wordcount.panel", await countCurrentPage());
});
let pending = null;
const refresh = () => { clearTimeout(pending); pending = setTimeout(async () =>
  nib.ui.postToPanel("dev.nib.wordcount.panel", await countCurrentPage()), 800); };
nib.events.on("tx.committed", refresh);
nib.events.on("page.changed", refresh);
```

`panel.html`

```html
<!doctype html><meta name="viewport" content="width=device-width">
<style>body{font:15px -apple-system;margin:16px;color:CanvasText;background:Canvas}b{font-size:32px}</style>
<p>Page <span id="p">–</span></p><b id="w">0</b> words
<script>
  nib.onMessage(m => { document.getElementById("p").textContent = m.page ?? "–";
                       document.getElementById("w").textContent = m.words; });
</script>
```

### 10.4 word-complete: brings back Goodnotes' discontinued Word Complete (uses the user's AI)

`main.js` (manifest: permissions `document:read`, `document:write`, `ai`; a command `dev.nib.wordcomplete.suggest` with `aiDirect: false`; object-menu entry for selected strokes)

```js
nib.commands.register("dev.nib.wordcomplete.suggest", async (p, ctx) => {
  const c = await ctx.execute("query.context");
  const refs = c.selection?.refs ?? [];
  const { text, lines } = await ctx.execute("recognize.items", { refs });
  const partial = text.trim().split(/\s+/).pop();
  const r = await nib.ai.complete({ tools: [], json: true, messages: [{ role: "user",
    text: `Complete the last word "${partial}" of: "${text}". Reply JSON {"options":["…","…","…"]}` }] });
  const options = JSON.parse(r.text).options;
  const pick = await nib.ui.choose("Complete word", options);
  if (pick == null) return;
  const last = lines[lines.length - 1];
  await ctx.execute("handwriting.replaceWord", { refs: last.words[last.words.length - 1].refs, text: options[pick] });
});
```

### 10.5 weekly-planner: a spec template with parameters

This is the manifest-only template shown in §5.6, plus an empty `main.js`. After installing, it appears under Templates › Planners.

## 11. Debugging

The developer console is at Settings › Plugins › Developer (F080). From there you can:

- choose a plugin and evaluate JS in its context;
- tail its console output;
- export `nib.d.ts`;
- create a new plugin skeleton;
- reload a plugin after editing its folder in Files.

Two safety mechanisms apply:

- **Watchdog.** A plugin that blocks longer than its timeout is marked unresponsive and its calls are rejected.
- **Safe mode.** Two crash-loops during start-up put the app in Safe Mode, where no plugins run.
