#!/usr/bin/env bash
# Standalone test for build/attach-release.sh's release-classification logic
# (prerelease flags, create-vs-edit/upload branching, changelog extraction).
# Runs entirely in a throwaway temp dir with a fake `gh` on PATH recording
# every call it receives - no real GitHub calls, no network, no framework.
#
# Usage: tests/attach-release.test.sh
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

changelog='# Changelog

## [Unreleased]

## [1.9.0-rc.1] - 2026-09-07

- rc notes line

## [1.8.0] - 2026-08-21

- stable notes line
'

# Fake `gh`: logs every invocation to $GH_CALLS_LOG, and lets a scenario
# control whether `gh release view` reports the release as already existing.
gh_fake='#!/usr/bin/env bash
echo "$*" >> "$GH_CALLS_LOG"
if [[ "$1 $2" == "release view" ]]; then
  exit "${FAKE_GH_VIEW_EXIT:-1}"
fi
exit 0
'

# run_scenario <name> <tag> <view-exit-code> <zip-name>
run_scenario() {
  local name="$1" tag="$2" view_exit="$3" zip="$4"
  local dir="$tmp_root/$name"
  mkdir -p "$dir"
  printf '%s' "$changelog" > "$dir/CHANGELOG.md"
  printf '%s' "$gh_fake" > "$dir/gh"
  chmod +x "$dir/gh"
  touch "$dir/$zip"
  (
    cd "$dir"
    export PATH="$dir:$PATH"
    export GH_TOKEN=fake
    export GH_CALLS_LOG="$dir/calls.log"
    export FAKE_GH_VIEW_EXIT="$view_exit"
    export GITHUB_REF_NAME="$tag"
    "$repo_root/build/attach-release.sh"
  )
}

# --- scenario 1: prerelease tag, release does not exist yet -> create -----
run_scenario s1 'v1.9.0-rc.1' 1 'SharePoint-Sharing-Manager-v1.9.0-rc.1.zip'
calls="$(cat "$tmp_root/s1/calls.log")"
echo "$calls" | grep -qx 'release view v1.9.0-rc.1' || fail "scenario1: missing release view call"
echo "$calls" | grep -q 'release create v1.9.0-rc.1 .*--notes-file notes.md --prerelease --latest=false' \
  || fail "scenario1: create call missing --prerelease --latest=false"
echo "$calls" | grep -q 'release edit' && fail "scenario1: unexpected edit call on a fresh release"
echo "$calls" | grep -q 'release upload' && fail "scenario1: unexpected upload call on a fresh release"
grep -qx -- '- rc notes line' "$tmp_root/s1/notes.md" || fail "scenario1: notes.md missing extracted rc section"
grep -q 'stable notes line' "$tmp_root/s1/notes.md" && fail "scenario1: notes.md leaked the next changelog section"
echo "PASS: prerelease tag with no existing release -> create with --prerelease --latest=false"

# --- scenario 2: prerelease tag, release already exists -> edit + upload --
run_scenario s2 'v1.9.0-rc.1' 0 'SharePoint-Sharing-Manager-v1.9.0-rc.1.zip'
calls="$(cat "$tmp_root/s2/calls.log")"
echo "$calls" | grep -qx 'release edit v1.9.0-rc.1 --prerelease --latest=false' \
  || fail "scenario2: missing edit call with prerelease flags"
echo "$calls" | grep -qx 'release upload v1.9.0-rc.1 SharePoint-Sharing-Manager-v1.9.0-rc.1.zip --clobber' \
  || fail "scenario2: missing upload call"
echo "$calls" | grep -q 'release create' && fail "scenario2: unexpected create call on an existing release"
echo "PASS: prerelease tag with existing release -> edit --prerelease --latest=false, then upload"

# --- scenario 3: stable tag, release does not exist yet -> create, no -----
# prerelease flags
run_scenario s3 'v1.8.0' 1 'SharePoint-Sharing-Manager-v1.8.0.zip'
calls="$(cat "$tmp_root/s3/calls.log")"
echo "$calls" | grep -qx 'release create v1.8.0 SharePoint-Sharing-Manager-v1.8.0.zip --notes-file notes.md' \
  || fail "scenario3: stable create call has unexpected shape/flags: $calls"
grep -qx -- '- stable notes line' "$tmp_root/s3/notes.md" || fail "scenario3: notes.md missing extracted stable section"
echo "PASS: stable tag with no existing release -> create with no prerelease flags"

echo "All attach-release.sh scenarios passed."
