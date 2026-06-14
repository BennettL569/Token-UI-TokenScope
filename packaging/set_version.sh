#!/usr/bin/env bash
# Bump the app version in one shot. The VERSION file is the source of truth that both packaging
# scripts read; this also propagates the number to the README badge and the Xcode MARKETING_VERSION
# entries (which can't read the VERSION file at build time). Remember to add a README changelog row.
#
# Usage: packaging/set_version.sh 1.2.0
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NEW="${1:-}"

if ! printf '%s' "$NEW" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "usage: $(basename "$0") X.Y.Z" >&2
  exit 1
fi

printf '%s\n' "$NEW" > "$ROOT/VERSION"
sed -i '' "s/version-[0-9][0-9.]*-7728ff/version-$NEW-7728ff/" "$ROOT/README.md"
sed -i '' "s/MARKETING_VERSION = [0-9][0-9.]*;/MARKETING_VERSION = $NEW;/g" "$ROOT/TokenScope.xcodeproj/project.pbxproj"

echo "Version set to $NEW:"
echo "  - VERSION file (read by build_app.sh / build_dmg.sh)"
echo "  - README badge"
echo "  - Xcode MARKETING_VERSION (all targets)"
echo "Next: add a '| **v$NEW** | … |' row to the README version history, then commit + tag."
