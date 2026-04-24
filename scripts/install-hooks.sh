#!/usr/bin/env bash
#
# Install git hooks from scripts/ into .git/hooks/.
# Run after `git clone` to set up the local quality gate.
# Project rule: no GitHub CI (CLAUDE.md §14); all checks run locally.

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
hooks_src="$repo_root/scripts"
hooks_dst="$repo_root/.git/hooks"

for hook in pre-push; do
    src="$hooks_src/$hook"
    dst="$hooks_dst/$hook"
    if [[ ! -f "$src" ]]; then
        echo "install-hooks: missing $src"
        exit 1
    fi
    cp "$src" "$dst"
    chmod +x "$dst"
    echo "install-hooks: installed $hook → $dst"
done

echo "install-hooks: done. Hooks active for this working copy."
echo "install-hooks: escape hatch — SKIP_PUSH_TESTS=1 git push"
