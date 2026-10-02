# Nib Agent

Use your **Claude subscription** or **ChatGPT subscription** in Nib. No API key is needed. Nib Agent runs on your Mac and uses the official Claude Code and Codex CLIs already signed in there.

1. Install Node.js 20 or newer and the official `claude` and/or `codex` CLI.
2. Run `claude` and sign in to your Claude subscription. Run `codex` and choose Sign in with ChatGPT. Complete a short conversation in Codex once so it caches your available models.
3. In this repository, run `node tools/agent/agent.mjs`.
4. On your iPad, open **Nib → Settings → AI → Claude — your subscription** or **ChatGPT — your subscription**. Paste the pairing string from the terminal and tap **Connect and use subscription**. Or select your Mac from the nearby list and paste its pairing token.
5. Allow Local Network access. Keep Nib open and both devices on the same Wi-Fi, or use Tailscale. In the Tailscale disclosure, enter the iPad’s Tailscale address so the Mac can reach its tool bridge.

To start automatically at login, run `tools/agent/install-macos.sh` once. Its LaunchAgent is `~/Library/LaunchAgents/app.nib.agent.plist`; the private log is `~/Library/Logs/nib-agent.log`. Do not move this folder after installing. To replace an existing installation, first run `launchctl bootout gui/$(id -u)/app.nib.agent` yourself, then rerun the installer.

On Windows/Linux, run the same Node command and enter the pairing string manually. Bonjour advertisement and the login installer are macOS-only. The CLIs must be native executables on PATH (or set `NIB_AGENT_CLAUDE` / `NIB_AGENT_CODEX` to their executable paths). Shell `.cmd` wrappers are deliberately not executed.

## Privacy and tools

The agent stores its bearer token in `~/.config/nib-agent/token` with private permissions. Treat the pairing string as a password. To revoke it, stop Nib Agent, remove that token file, restart, and pair again. LAN HTTP is unencrypted: use only a trusted LAN or Tailscale. Do not forward port 7332 to the public internet.

Every POST contains the whole conversation. Private turn directories, image files, and generated CLI configuration are deleted after the turn. The server does not log prompts or answers. Subscription providers still process your notes on Anthropic’s/OpenAI’s servers and enforce your plan’s limits.

Claude runs with no built-in tools, only the request’s Nib MCP tools, `dontAsk`, strict MCP configuration, no skills, no hooks, no Chrome and no session persistence. Codex runs with an empty private working directory, read-only sandbox, ignored user config/rules, disabled shell/web/image/file-edit/agent/plugin tools, and a per-request copy of its cached model catalogue with patch capabilities removed, direct tool mode, and multi-agent overrides disabled. Goals are disabled too. Only the scoped MCP handoff server is automatically approved by Codex; actual note actions still use Nib’s confirmation policy. Authentication stays in the official CLI’s own credential storage. Claude’s auth-status preflight requires a Claude subscription login, and Codex forces ChatGPT login; stored API-key logins are not silently used. API-key and inherited host-session environment variables are removed. The default ChatGPT model is chosen by Codex from its catalogue.

The in-app scoped MCP handoff endpoint supplies `{bridge:{url,token,mode:"handoff"}}` on each tool-capable request. The agent connects the CLI through an authenticated loopback MCP proxy. A tool call yields a protocol `toolCall` and `stop(tool_use)`, then stops that CLI process. Nib executes the call in its existing agent loop, applies Ask mode, the original caller’s permissions and confirmation policy, tracks changes, and keeps one Undo group. The next request contains the result. The one-use capability expires with that request; the library-wide external bridge token is never sent to the Mac.

Text, image understanding, study questions, writing/handwriting assistance, math explanations and meeting summaries use the active provider. Dedicated audio transcription and bitmap image generation are not endpoints in Nib Agent Protocol v1: use Nib’s on-device transcription/Image Playground where available, or configure an API provider for those endpoints. CLI output budgets are controlled by the CLI/model; `maxTokens` and `temperature` are advisory on these subscription routes.

## Troubleshooting

- **Cannot reach Nib Agent:** start the Node command, check the Mac address and firewall, and allow Local Network on the iPad.
- **Not logged in:** open `claude` or `codex` on the Mac and sign in again. A CLI may report a saved login even after its OAuth token expires.
- **Tool bridge disconnected:** keep Nib in the foreground and check that the Mac can reach the iPad’s Wi-Fi/Tailscale address.
- **Usage limit:** wait for your subscription’s limit to reset.
- **CLI upgrade changes tools:** rerun the tests and real restriction smoke before using that version. The implementation was checked against Claude Code’s installed help and Codex 0.159.3.

Settings: `NIB_AGENT_PORT` (7332), `NIB_AGENT_BIND` (0.0.0.0), `NIB_AGENT_HOST` (advertised pairing address), `NIB_AGENT_HOME` (private state directory), `NIB_AGENT_CLAUDE`, `NIB_AGENT_CODEX`.

## Tests

```sh
node --test tools/agent
node tools/agent/smoke.mjs
NIB_SMOKE_PROMPT='List only your available tool names in one short sentence.' node tools/agent/smoke.mjs
NIB_SMOKE_MODELS=chatgpt NIB_SMOKE_TOOLS=1 NIB_SMOKE_PROMPT='Call nib_context once.' node tools/agent/smoke.mjs
```

Unit tests use fake executables and no subscriptions. The smoke starts a loopback agent, makes one tiny request per subscription using curl, and shuts it down. Tests and smokes put temporary files inside this directory, then remove them; they do not use `/tmp`.
