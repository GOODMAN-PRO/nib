#!/bin/sh
set -eu
umask 077
if [ "$(uname -s)" != Darwin ]; then
  echo 'This installer is for macOS. On Windows or Linux run: node tools/agent/agent.mjs' >&2
  exit 1
fi
AGENT_NODE=$(command -v node)
AGENT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
export AGENT_NODE AGENT_ROOT
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs" "$HOME/.config/nib-agent"
touch "$HOME/Library/Logs/nib-agent.log"
chmod 600 "$HOME/Library/Logs/nib-agent.log"
node --input-type=module <<'JS'
import { writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
const esc = s => s.replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;').replaceAll('"','&quot;');
const home = homedir();
const values = [process.env.AGENT_NODE, process.env.AGENT_ROOT + '/agent.mjs'];
const envPath = process.env.PATH;
const log = home + '/Library/Logs/nib-agent.log';
const xml = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>app.nib.agent</string>
<key>ProgramArguments</key><array>${values.map(x=>`<string>${esc(x)}</string>`).join('')}</array>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
<key>EnvironmentVariables</key><dict><key>PATH</key><string>${esc(envPath)}</string></dict>
<key>StandardOutPath</key><string>${esc(log)}</string>
<key>StandardErrorPath</key><string>${esc(log)}</string>
<key>WorkingDirectory</key><string>${esc(home + '/.config/nib-agent')}</string>
</dict></plist>`;
writeFileSync(home + '/Library/LaunchAgents/app.nib.agent.plist', xml, { mode: 0o600 });
JS
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/app.nib.agent.plist"
echo 'Nib Agent will run when you log in. Find its pairing string in ~/Library/Logs/nib-agent.log.'
echo 'Keep this tools/agent folder in place. To uninstall: launchctl bootout gui/$(id -u)/app.nib.agent, then remove the plist.'
