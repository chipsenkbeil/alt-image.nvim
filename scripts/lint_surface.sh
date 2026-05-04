#!/usr/bin/env bash
# Asserts the strict public-surface rule: only init.lua, iterm2.lua,
# sixel.lua may have M._<name> declarations, and the only allowed
# name is _supported.
set -euo pipefail

FILES=(
    lua/alt-img/init.lua
    lua/alt-img/iterm2.lua
    lua/alt-img/sixel.lua
)

bad=0
for f in "${FILES[@]}"; do
    while IFS= read -r line; do
        # Match `function M._<name>` and `M._<name> =`, except _supported.
        if [[ "$line" =~ M\._([a-z_]+) ]]; then
            name="${BASH_REMATCH[1]}"
            if [[ "$name" != "supported" ]]; then
                echo "lint: $f: forbidden M._$name (only _supported allowed)"
                bad=1
            fi
        fi
    done < <(grep -nE '(function M\._|^M\._|^[[:space:]]*M\._)[a-z_]+' "$f" || true)
done

if [[ $bad -ne 0 ]]; then
    exit 1
fi

echo "lint: public surface clean"
