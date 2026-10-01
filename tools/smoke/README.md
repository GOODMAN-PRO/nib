# Device smoke scripts

Nib is built without a Mac, so a sideloaded build is checked on the device through the in-app MCP/HTTP bridge
(docs/AI.md §9). `run.mjs` plays the `*.json` scripts in this folder against the bridge: each script is a list of tool
calls with expectations, plus the checks only a person at the iPad can make.

- Runner: F090. Scripts (`canvas.json`, `ink.json`, `sync.json`, `presentation.json`): F111.
- Node 18 or newer. No `npm install`: the runner uses only Node's standard library.

## Running

1. On the iPad: Settings › Bridge › turn the bridge on. Keep Nib in the foreground (iOS suspends the listener in the
   background; it comes back when Nib does).
2. Copy the URL and the token from the same page. The PC must be on the same Wi-Fi, or on Tailscale.
3. Run:

```bash
export NIB_BRIDGE_URL=http://192.168.1.20:7331        # or http://ipad.tail1234.ts.net:7331
export NIB_BRIDGE_TOKEN=nib_4qV...
node tools/smoke/run.mjs                 # every script
node tools/smoke/run.mjs ink canvas      # some scripts (name, file name or path)
node tools/smoke/run.mjs --list          # what would run, without a device
```

PowerShell: `$env:NIB_BRIDGE_URL = "http://192.168.1.20:7331"`, `$env:NIB_BRIDGE_TOKEN = "nib_..."`.

| Option | Meaning |
|---|---|
| `--url <url>` | Bridge address (`NIB_BRIDGE_URL`, default `http://127.0.0.1:7331`). A trailing `/mcp` is fine. |
| `--token <token>` | Bearer token (`NIB_BRIDGE_TOKEN`). |
| `--var name=value` | Sets a script variable; repeatable. JSON values are parsed (`--var n=3`, `--var doc=doc:D4F9T2M8K1QZ`). |
| `--out <dir>` | Where renders and `report.json` go. Default: a new `nib-smoke-<run>` folder in the temp directory. |
| `--timeout <s>` | Per-request limit (default 130 s; the bridge itself gives up on an unanswered confirmation after 120 s). |
| `--no-manual` | Never prompt; manual checks are listed at the end instead. |
| `--bail` | Stop after the first failing script. |
| `-v`, `--verbose` | Print every result. |

Exit code: `0` when nothing failed (skipped and manual steps are allowed), `1` when a step failed, `2` for usage or
connection errors (bridge off, wrong token, wrong network).

**Claude Code.** Run it non-interactively: every `manual` step is then reported as "needs a person" and listed at the end,
so ask the user those questions, or have them run the same command in a terminal where the runner prompts
`[y]es / [n]o / [s]kip`. Renders (`nib_render` results and image downloads) are saved next to `report.json`; open them
to look at the page.

## Script format

A script is a JSON object (or just an array of steps):

```json
{
  "name": "Ink",
  "description": "Pen strokes commit, render and undo on the device",
  "requires": ["ink.addStrokes", "render.page"],
  "vars": { "color": "#1E3A8A" },
  "steps": [
    { "tool": "nib_context", "save": { "doc": "document.ref" } },
    { "name": "add a page", "command": "page.add",
      "params": { "doc": "${doc}", "position": "end", "id": "PG${run}" },
      "expect": { "json": { "changes": { "created": { "$len": 1 } } } },
      "save": { "page": "changes.created[0]" } },
    { "manual": "Open the new last page and draw a zig-zag with the Pencil. Does the ink follow the tip without lag?" },
    { "waitEvent": { "type": "tx.committed", "match": { "principal": "user" }, "timeout": 60 } },
    { "name": "render", "tool": "nib_render", "args": { "page": "${page}" }, "expect": { "image": true } },
    { "name": "undo", "command": "edit.undo", "params": { "doc": "${doc}" } }
  ],
  "cleanup": [
    { "command": "page.trash", "params": { "pages": ["${page}"] } }
  ]
}
```

- `requires`: command ids the script needs. When the build does not have one, the script is **skipped**, not failed.
- `vars`: initial variables. Built in: `${run}` (a unique run id such as `SMKLZ3K9Q1A`, valid in caller-chosen ids) and
  `${script}`.
- `steps` run in order. After a failed step the rest are "not run" (they usually depend on it).
- `cleanup` always runs at the end, even after a failure. A cleanup step whose variables were never set is skipped.
- A script with no steps (`{}`) is skipped.

### Steps

Every step may have a `name`, `expect`, `save`, and `optional: true` (a failure is then only a warning).

| Step | Does |
|---|---|
| `{"tool": "nib_get", "args": {…}}` | MCP `tools/call`: any tool from `tools/list` (`nib_context`, `nib_get`, `nib_find`, `nib_search`, `nib_page_text`, `nib_render`, `nib_commands`, `nib_command_schema`, `nib_run`, `nib_events` and the direct tools such as `ink__writeText`). `arguments` works too. |
| `{"command": "page.add", "params": {…}, "dryRun": false}` | Shorthand for `nib_run {command, params, dry_run}`, the same path an agent uses (the device confirms destructive calls). |
| `{"method": "tools/list", "params": {…}}` | A raw JSON-RPC request. |
| `{"http": {"method": "GET", "path": "/health", "auth": true, "body": {…}}}` | A raw HTTP request, e.g. `POST /api/v1/call` or an asset link from a result (full URLs are fetched from the same bridge). |
| `{"waitEvent": {"type": "tx.committed", "doc": "D4F9T2M8K1QZ", "match": {…}, "timeout": 30}}` | Long-polls `nib_events` until an event matches. Events count from the start of the script, so an event caused during an earlier manual step is found. `doc` is the bare document id. `"waitEvent": "page.changed"` is short for `{type}`. |
| `{"wait": 2}` | Sleeps for that many seconds. |
| `{"manual": "question for the person at the iPad"}` | A check only a person can make (latency, palm rejection, AirPlay, rotation). |

### Expectations

Tool, command, JSON-RPC and event steps must succeed unless `expect` says otherwise; HTTP steps must answer below 400.

| Key | Checks |
|---|---|
| `json` | The result's JSON (a tool's text part parsed; results over 20 KB are joined across pages first). Subset match: objects need only the keys listed; arrays match element by element with the same length; other values must be equal. |
| `ok` / `isError` | `"ok": false` (or `"isError": true`) expects a failure. |
| `error` | The error code (`"user_denied"`, `"not_found"`, a JSON-RPC number such as `-32602`); implies a failure. |
| `text` | A string the raw text must contain, or a matcher. |
| `image` | `true`: the result has an image part (renders) or the HTTP answer is an image. |
| `status` | HTTP status of an `http` step (a number or a matcher). |
| `maxMs` | The request took at most this many milliseconds. |

Matchers can stand anywhere a value is expected: `{"$exists": true}`, `{"$eq": …}`, `{"$ne": …}`,
`{"$match": "^page:"}` (regex), `{"$gt": 1}`, `{"$gte": …}`, `{"$lt": …}`, `{"$lte": …}`, `{"$len": 3}`,
`{"$minLen": 1}`, `{"$maxLen": …}` (strings count characters, arrays elements, objects keys), `{"$contains": …}`
(substring, or an array element that matches), `{"$type": "string" | "number" | "boolean" | "array" | "object" | "null"}`,
`{"$oneOf": [...]}` and `{"$not": …}`. Several keys in one matcher must all hold.

### Variables

`"save": {"name": "path"}` stores part of a passing result: `"document.ref"`, `"results[0].value.ref"`, `"$"` for the whole
result, `"$text"` for the raw text. For a `waitEvent` step the result is the matching event.
`${name}` (paths allowed, e.g. `${ctx.page}`) is replaced everywhere in later steps; a string that is exactly one
`${name}` keeps the variable's JSON type (object, number). An unknown variable fails the step.

## Output

One line per step (`ok`, `FAIL` with the reasons, `warn`, `skip`, `manual`, `-` for not run), then a summary, the list of
manual checks, and the folder holding `report.json` (every step's status, timing, problems and the first 4 KB of its
output) and the saved images (`<script>-<step>.png`, or the step's `saveImage` file name).
