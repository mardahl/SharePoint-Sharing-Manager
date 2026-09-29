#!/usr/bin/env bash
# Regenerate docs/screenshots/{targets,findings,aggregate}.svg from the real TUI.
# Runs the app offline in a throwaway sandbox (own HOME, fictional contoso cache);
# no tenant connection is made and the real user config is never read or written.
# Usage (from anywhere): build/screenshots/capture.sh
# Requires: tmux, pwsh (7.4+), python3.
set -euo pipefail

for c in tmux pwsh python3; do
  command -v "$c" >/dev/null || { echo "error: '$c' is required but not found in PATH" >&2; exit 1; }
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
OUT="$REPO/docs/screenshots"
SES="ssmshot-$$"
SBX="$(mktemp -d)"
trap 'tmux kill-session -t "$SES" 2>/dev/null || true; rm -rf "$SBX"' EXIT

mkdir -p "$SBX/app" "$SBX/home" "$OUT"
tar -C "$REPO" --exclude=.git --exclude='*.log' --exclude=SSM-Cache --exclude=SSM-Exports \
    --exclude=dist --exclude=wiki-remote --exclude=docs -cf - . | tar -C "$SBX/app" -xf -
mkdir -p "$SBX/app/SSM-Cache/contoso"
python3 "$HERE/gen-demo-cache.py" "$SBX/home/.sharepoint-sharing-manager.json" "$SBX/app/SSM-Cache/contoso/session.json"

tmux new-session -d -s "$SES" -x 130 -y 34 -c "$SBX/app" \
  "env HOME='$SBX/home' LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 pwsh -NoProfile -File ./SharePoint-Sharing-Manager.ps1"

screen() { tmux capture-pane -p -t "$SES"; }
# wait_for TEXT: poll the plain screen until TEXT appears (20 s timeout).
wait_for() {
  local i
  for i in $(seq 1 100); do
    screen | grep -qF -- "$1" && return 0
    sleep 0.2
  done
  echo "error: timed out waiting for '$1'. Last screen:" >&2; screen >&2; exit 1
}
# key WAITTEXT KEY...: send keys, then wait for WAITTEXT.
key() { local w="$1"; shift; tmux send-keys -t "$SES" "$@"; wait_for "$w"; }
# nav KEY...: send navigation keys with no expected text change, brief settle.
nav() { tmux send-keys -t "$SES" "$@"; sleep 0.3; }
snap() { tmux capture-pane -e -p -t "$SES" > "$SBX/$1.ans"; python3 "$HERE/ansi2svg.py" "$SBX/$1.ans" "$OUT/$1.svg"; echo "wrote $OUT/$1.svg"; }

wait_for "13 of 13 sites"

# 1. targets: OneDrives tab, Ana/Kim/Mia selected, cursor on Lars Holm
key "12 of 12 OneDrives" 2
nav Home; nav Space; nav Down Down Down; nav Space; nav Down; nav Space; nav Up Up
wait_for "3 selected"
snap targets

# 2. findings: drill into Ana Silva, 2 rows selected
nav Home; key "8 of 8 findings" Enter
nav Down; nav Space; nav Down Down Down; nav Space; nav Down
wait_for "2 selected"
snap findings

# 3. aggregate: Sites tab, all-findings view, 2 rows selected
nav Escape; key "13 of 13 sites" 1
key "All sites" g
nav Down Down; nav Space; nav Down Down Down Down Down Down Down; nav Space; nav Down Down
wait_for "2 selected"
snap aggregate
