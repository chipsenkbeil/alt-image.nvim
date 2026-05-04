#!/usr/bin/env bash
# Verifies that docs/API.md's pinned upstream SHAs still resolve in
# ~/projects/neovim. Warns if upstream master has moved past the pin
# without docs/API.md being bumped.
set -euo pipefail

API_DOC="docs/API.md"
NEOVIM_REPO="${NEOVIM_REPO:-$HOME/projects/neovim}"

if [[ ! -d "$NEOVIM_REPO" ]]; then
    echo "verify-api: $NEOVIM_REPO not found; set NEOVIM_REPO env var" >&2
    exit 2
fi

# Extract pinned SHAs from docs/API.md (rows in the §1 table).
MASTER_PIN=$(grep -E '^\| `runtime/lua/vim/ui/img\.lua` \(master\) \|' "$API_DOC" \
    | sed -E 's/.*`([0-9a-f]+)`.*/\1/')
PR_PIN=$(grep -E '^\| PR #39496' "$API_DOC" \
    | sed -E 's/.*`([0-9a-f]+)`.*/\1/')

if [[ -z "$MASTER_PIN" || -z "$PR_PIN" ]]; then
    echo "verify-api: could not extract pinned SHAs from $API_DOC" >&2
    exit 2
fi

echo "verify-api: master pin = $MASTER_PIN"
echo "verify-api: pr-39496 pin = $PR_PIN"

# Verify each pin resolves.
git -C "$NEOVIM_REPO" rev-parse --verify "$MASTER_PIN" >/dev/null
git -C "$NEOVIM_REPO" rev-parse --verify "$PR_PIN" >/dev/null

# Warn (don't fail) if upstream/master has moved past the master pin.
UPSTREAM_HEAD=$(git -C "$NEOVIM_REPO" rev-parse origin/master 2>/dev/null || \
                git -C "$NEOVIM_REPO" rev-parse master)
if [[ "$UPSTREAM_HEAD" != "$MASTER_PIN"* ]]; then
    echo "verify-api: WARNING upstream master ($UPSTREAM_HEAD) has moved past pin ($MASTER_PIN)"
    echo "verify-api: review diff and bump docs/API.md if vim/ui/img.lua changed:"
    echo "  git -C $NEOVIM_REPO diff $MASTER_PIN..master -- runtime/lua/vim/ui/img.lua"
fi

echo "verify-api: pinned SHAs resolve in $NEOVIM_REPO"
