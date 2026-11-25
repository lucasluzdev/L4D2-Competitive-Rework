#!/usr/bin/env bash
# Verify that every `sm plugins load <path>` in cfg/ points to an existing .smx
# under addons/sourcemod/plugins/. Commented-out lines are ignored.
# Exits 1 if any plugin is missing, so it can be used as a pre-commit hook.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGINS_DIR="$ROOT/addons/sourcemod/plugins"
missing=0
checked=0

while IFS=: read -r file line content; do
    content="${content%$'\r'}"                         # tolerate CRLF configs
    path="$(awk '{print $4}' <<<"$content")"
    [[ -z "$path" ]] && continue
    [[ "$path" == *.smx ]] || path="$path.smx"
    checked=$((checked + 1))
    if [[ ! -f "$PLUGINS_DIR/$path" ]]; then
        echo "MISSING: $path  (${file#"$ROOT/"}:$line)"
        missing=$((missing + 1))
    fi
done < <(grep -rnE '^[[:space:]]*sm[[:space:]]+plugins[[:space:]]+load[[:space:]]+' "$ROOT/cfg" || true)

if (( missing > 0 )); then
    echo "$missing of $checked plugin load(s) point to missing files."
    exit 1
fi
echo "OK: all $checked plugin load(s) resolve."
