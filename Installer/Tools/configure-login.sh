#!/bin/zsh
set -euo pipefail
# Preserve an explicit service-off preference during upgrades.
if [[ "$(/usr/bin/defaults read local.omen.control fanServiceEnabled 2>/dev/null || true)" == 0 ]]; then
    print 'Preserved disabled background-service preference.'
    exit 0
fi
mkdir -p "$HOME/Library/LaunchAgents"
agent="$HOME/Library/LaunchAgents/local.omen.login.control.plist"
temp_agent=$(/usr/bin/mktemp "$HOME/Library/LaunchAgents/.omen-agent.XXXXXX")
trap '/bin/rm -f "$temp_agent"' EXIT
cat > "$temp_agent" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>local.omen.login.control</string>
<key>ProgramArguments</key><array><string>/Applications/OmenControl.app/Contents/MacOS/OmenControl</string><string>--background</string></array>
<key>RunAtLoad</key><true/><key>LimitLoadToSessionType</key><array><string>Aqua</string></array>
<key>ProcessType</key><string>Interactive</string>
<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
<key>ThrottleInterval</key><integer>10</integer>
</dict></plist>
PLIST
/usr/bin/plutil -lint "$temp_agent"
/bin/chmod 644 "$temp_agent"
/bin/mv -f "$temp_agent" "$agent"
/bin/launchctl enable "gui/$(/usr/bin/id -u)/local.omen.login.control"
# Do not start manual fan control during installation. RunAtLoad starts at next login.
print 'Quiet login configured for the next login.'
