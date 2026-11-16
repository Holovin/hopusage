#!/usr/bin/env bash
set -euo pipefail

# Fork: prints the GitHub Release notes for a fork version: that version's section of CHANGELOG.md,
# then how to install an un-notarized build. Fails when the changelog has no section for the version,
# so a release never ships without notes.
#
# Usage: fork_release_notes.sh [version]   (default: the FORK_VERSION file)

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-$(tr -d '[:space:]' < "$ROOT_DIR/FORK_VERSION")}"

# Everything between this version's "## v<version>" heading and the next "## " heading.
SECTION="$(awk -v heading="## v$VERSION" '
  $0 == heading { found = 1; next }
  found && /^## / { exit }
  found { print }
' "$ROOT_DIR/CHANGELOG.md")"

if [ -z "$(printf '%s' "$SECTION" | tr -d '[:space:]')" ]; then
  echo "CHANGELOG.md has no section '## v$VERSION'. Add it in the commit that bumps FORK_VERSION." >&2
  exit 1
fi

# Trim the blank lines around the section.
printf '%s\n' "$SECTION" | sed -e '/./,$!d' | sed -e ':a' -e '/^\n*$/{$d;N;ba' -e '}'

cat <<'NOTES'

---

### Install

Universal build (Apple Silicon and Intel), macOS 15 or later.

This build is not notarized by Apple, so macOS blocks it on first launch. After dragging HopUsage to
Applications, run this once in Terminal:

```bash
xattr -dr com.apple.quarantine /Applications/HopUsage.app
```

macOS asks for Keychain access again after every update, because the build is signed without a
developer certificate.
NOTES
