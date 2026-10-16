#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
[[ -d "$project_dir/dist/OmenControl.app" ]] || { print -u2 'Run build-app.sh first.'; exit 1; }
/usr/bin/osascript -e 'tell application "/Applications/OmenControl.app" to quit' >/dev/null 2>&1 || true
agent="$HOME/Library/LaunchAgents/local.omen.login.control.plist"
/bin/launchctl bootout "gui/$(id -u)/local.omen.login.control" >/dev/null 2>&1 || true
/usr/bin/ditto "$project_dir/dist/OmenControl.app" /Applications/OmenControl.app
mkdir -p "$HOME/Library/LaunchAgents"
/usr/bin/python3 - "$agent" <<'PY'
import plistlib,sys
with open(sys.argv[1],'wb') as f:
 plistlib.dump({'Label':'local.omen.login.control','ProgramArguments':['/Applications/OmenControl.app/Contents/MacOS/OmenControl','--background'],'RunAtLoad':True,'LimitLoadToSessionType':['Aqua'],'ProcessType':'Interactive','KeepAlive':{'SuccessfulExit':False},'ThrottleInterval':10},f)
PY
chmod 644 "$agent"
/bin/launchctl bootstrap "gui/$(id -u)" "$agent"
print 'OMEN Control installed. Its menu-bar service starts quietly at login.'
