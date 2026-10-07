#!/usr/bin/env bash
# Builds the Windows usage exporter (x64 + ARM64) and packages it, with README.txt, as
# dist/windows-exporter/TokenScopeExport-windows-<version>.zip.
#
# By default the package also gets pricing.json: this Mac's TokenScope pricing table, so exported
# costs match what the Mac app computes. Set INCLUDE_PRICING=0 for a generic package (for example
# a public release asset), which falls back to TokenScope's default prices.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT="$ROOT/dist/windows-exporter"
PKG="$OUT/TokenScopeExport"
VERSION="$(sed -nE 's/^const version = "(.*)"/\1/p' "$HERE/main.go")"
DB="$HOME/Library/Application Support/TokenScope/usage.sqlite"

cd "$HERE"
go vet ./...
go test -count=1 ./...

rm -rf "$OUT"
mkdir -p "$PKG"
GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o "$PKG/TokenScopeExport.exe" .
GOOS=windows GOARCH=arm64 CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o "$PKG/TokenScopeExport-arm64.exe" .
cp "$HERE/README.txt" "$PKG/README.txt"

if [[ "${INCLUDE_PRICING:-1}" == 1 && -f "$DB" ]]; then
  # Read-only; rows in the order the Mac app loads them (the first model-only match wins).
  sqlite3 "file:${DB// /%20}?mode=ro" "SELECT json_group_array(json_object(
      'tool', tool, 'model', model, 'inputPerMillion', input_per_million,
      'outputPerMillion', output_per_million, 'cachePerMillion', cache_per_million))
    FROM (SELECT * FROM model_pricing ORDER BY tool, model);" > "$PKG/pricing.json"
  echo "Included this Mac's pricing table ($(grep -o '"model"' "$PKG/pricing.json" | wc -l | tr -d ' ') rows)."
else
  echo "No pricing.json included; the exporter will use TokenScope's default prices."
fi

(cd "$OUT" && zip -qrX "TokenScopeExport-windows-$VERSION.zip" TokenScopeExport)
echo "Built $OUT/TokenScopeExport-windows-$VERSION.zip"
