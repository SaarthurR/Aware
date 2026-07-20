#!/bin/zsh
# Streamlines the iPhone side of Aware:
#   1. Builds the single-file Scriptable bundle (AwareRemoteBundle.js).
#   2. Delivers it to Scriptable via iCloud Drive if that folder exists, so the
#      script appears on the iPhone with no copy-paste.
#   3. Stages a config blob on the clipboard so the phone "Paste config from
#      clipboard" action can finish setup in one tap (needs Universal Clipboard).
#
# This script NEVER touches power settings, sudo, or the Mac LaunchDaemon.
#
# Usage:
#   Resources/scripts/phone-setup.sh 'https://YOUR-WORKER.workers.dev' 'phone-v1'
#
# You will be prompted for the phone secret at a masked prompt; it is only placed
# on the local clipboard, never printed or written to disk.

set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
readonly PATH

if [[ "$#" -ne 2 ]]; then
  echo "Usage: $0 <https-worker-url> <phone-key-id>" >&2
  exit 64
fi

endpoint="${1%/}"
kid="$2"

if [[ "$endpoint" != https://* ]]; then
  echo "Worker URL must be an HTTPS base URL (not the wss:// host socket URL)." >&2
  exit 64
fi
if [[ ! "$kid" =~ ^[A-Za-z0-9._-]{1,64}$ ]]; then
  echo "Key ID looks invalid; expected something like phone-v1." >&2
  exit 64
fi

script_dir="${0:A:h}"
repo_root="${script_dir:h:h}"
shortcut_dir="$repo_root/shortcut"
bundle="$shortcut_dir/AwareRemoteBundle.js"

if ! command -v node >/dev/null 2>&1; then
  echo "node is required to build the bundle. Install Node.js 20+ and retry." >&2
  exit 69
fi

echo "Building single-file Scriptable bundle..."
node "$shortcut_dir/build-bundle.mjs"

# Deliver via iCloud Drive if Scriptable's synced folder exists.
scriptable_dir="$HOME/Library/Mobile Documents/iCloud~dk~simonbs~Scriptable/Documents"
if [[ -d "$scriptable_dir" ]]; then
  /bin/cp -f "$bundle" "$scriptable_dir/AwareRemote.js"
  echo "Delivered AwareRemote.js to Scriptable via iCloud Drive."
  echo "It will appear on your iPhone's Scriptable app once iCloud syncs."
else
  echo "Scriptable iCloud folder not found at:"
  echo "  $scriptable_dir"
  echo "Install Scriptable on the iPhone with iCloud enabled, then re-run this,"
  echo "or paste $bundle into a new Scriptable script named AwareRemote by hand."
fi

# Read the phone secret without echoing it.
printf 'Enter phone base64url secret (input hidden): '
stty -echo
read secret
stty echo
printf '\n'
secret="${secret//[[:space:]]/}"
if [[ "${#secret}" -lt 43 ]]; then
  echo "Secret must be a 32-byte base64url value (>= 43 chars)." >&2
  exit 65
fi

# Stage the config on the clipboard for the phone's one-tap paste setup.
config_json=$(/usr/bin/printf '{"endpoint":"%s","kid":"%s","secret":"%s"}' "$endpoint" "$kid" "$secret")
printf '%s' "$config_json" | /usr/bin/pbcopy
unset secret config_json

echo
echo "Config copied to this Mac's clipboard."
echo "On the iPhone: open Scriptable, run AwareRemote, choose 'Reconfigure' ->"
echo "'Paste config from clipboard'. Then clear your clipboard by copying anything else."
