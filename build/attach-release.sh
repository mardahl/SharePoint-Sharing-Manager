#!/usr/bin/env bash
# Attaches the release zip to the GitHub release for the tag that triggered
# this run. Called from .github/workflows/release.yml's "Attach to release"
# step; also exercised directly (with a mocked `gh`) by
# tests/attach-release.test.sh.
#
# Requires in the environment: GITHUB_REF_NAME (e.g. v1.9.0-rc.1), GH_TOKEN.
# Requires in the working directory: CHANGELOG.md and one
# SharePoint-Sharing-Manager-*.zip file.
set -eo pipefail

ver="${GITHUB_REF_NAME#v}"
awk -v ver="$ver" '
  $0 ~ "^## \\[" ver "\\]" { flag=1; next }
  flag && /^## \[/ { exit }
  flag { print }
' CHANGELOG.md > notes.md

# A tag with a '-' suffix (e.g. v1.9.0-rc.1) is a prerelease: mark it as such
# and never let it replace the "Latest" stable release.
prerelease_flags=()
if [[ "$ver" == *-* ]]; then
  prerelease_flags=(--prerelease --latest=false)
fi

if gh release view "$GITHUB_REF_NAME" >/dev/null 2>&1; then
  if [[ ${#prerelease_flags[@]} -gt 0 ]]; then
    gh release edit "$GITHUB_REF_NAME" --prerelease --latest=false
  fi
  gh release upload "$GITHUB_REF_NAME" SharePoint-Sharing-Manager-*.zip --clobber
else
  gh release create "$GITHUB_REF_NAME" SharePoint-Sharing-Manager-*.zip \
    --notes-file notes.md "${prerelease_flags[@]}"
fi
