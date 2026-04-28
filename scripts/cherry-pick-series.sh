#!/usr/bin/env bash
# Cherry-pick a list of upstream commits into the current branch, recording
# any conflicts to a per-series conflict folder. Stops on first conflict so a
# human (or Claude) can resolve, then re-run continues from the next commit.
#
# Usage: cherry-pick-series.sh <series-dir> <base-branch>
#   <series-dir> e.g. workspace/kernel/patches/phase2-bpf-backport/01-bpf-link
#   reads <series-dir>/commit-candidates.txt (one "<hash> <subject>" per line)
#   writes <series-dir>/conflicts/<hash>.conflict on conflict
#   writes <series-dir>/applied.txt as the running success log
#   <base-branch> is checked out as the starting point if branch doesn't exist
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERIES_DIR="${1:?series-dir required}"
BASE_BRANCH="${2:?base-branch required}"
KERNEL="$ROOT/workspace/kernel/android_kernel_xiaomi_sm8250"

CANDIDATES="$SERIES_DIR/commit-candidates.txt"
APPLIED="$SERIES_DIR/applied.txt"
CONFLICT_DIR="$SERIES_DIR/conflicts"
mkdir -p "$CONFLICT_DIR"
touch "$APPLIED"

cd "$KERNEL"

# Make sure linux-stable remote exists for cherry-picks
git remote get-url linux-stable >/dev/null 2>&1 || \
  git remote add linux-stable "$ROOT/workspace/kernel/linux-stable"
git fetch linux-stable --tags 2>/dev/null || true

# Determine target branch from series-dir name (research-p2-s<N>)
target_branch=$(basename "$SERIES_DIR" | sed -E 's/^([0-9]+)-.*/research-p2-s\1/')
echo "[info] series=$(basename $SERIES_DIR) target_branch=$target_branch base=$BASE_BRANCH"

# Create or switch to the series branch
if git rev-parse --verify "$target_branch" >/dev/null 2>&1; then
  git checkout "$target_branch"
else
  git checkout "$BASE_BRANCH"
  git checkout -b "$target_branch"
fi

while IFS= read -r line; do
  [[ -z "$line" || "${line#\#}" != "$line" ]] && continue
  hash="${line%% *}"
  if grep -qF "$hash" "$APPLIED" 2>/dev/null; then
    echo "[skip] $hash already applied"
    continue
  fi
  echo "[pick] $hash $line"
  if git cherry-pick -x "$hash"; then
    echo "$hash $line" >> "$APPLIED"
  else
    echo "[conflict] $hash — see $CONFLICT_DIR/$hash.conflict"
    git diff > "$CONFLICT_DIR/$hash.conflict"
    echo "$hash $(date)" >> "$CONFLICT_DIR/index.txt"
    git cherry-pick --abort
    echo "STOP — fix conflict, then re-run this script to continue from next commit"
    exit 1
  fi
done < "$CANDIDATES"

echo "[done] series complete: $(wc -l < "$APPLIED") commits applied"
