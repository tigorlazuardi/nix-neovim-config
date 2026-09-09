#!/usr/bin/env bash
# Update flake inputs in an updater-owned clone, verify, commit, and push.
set -u -o pipefail

log() { printf 'daily-update: %s\n' "$1"; }
fail() { log "failed: $1"; exit 1; }

old_revision=$(git rev-parse HEAD) || fail 'cannot read current revision'
nix flake update || fail 'flake update failed'

if git diff --quiet -- flake.lock; then
  log 'inputs unchanged'
  nix flake check || fail 'flake check failed'
  git diff --check || fail 'whitespace check failed'
  exit 0
fi

log 'inputs changed; checks started'
nix flake check || fail 'flake check failed'
git diff --check || fail 'whitespace check failed'
git add flake.lock
git commit -m 'chore(deps): update flake inputs' || fail 'commit failed'

attempt=0
while :; do
  git fetch --quiet origin main || fail 'fetch before push failed'
  if ! git rebase origin/main; then
    git rebase --abort || true
    fail 'rebase before push failed'
  fi
  nix flake check || fail 'flake check after rebase failed'
  git diff --check || fail 'whitespace check after rebase failed'
  if git push origin HEAD:main; then
    log "updated $old_revision to $(git rev-parse HEAD)"
    exit 0
  fi
  attempt=$((attempt + 1))
  [ "$attempt" -le 1 ] || fail 'concurrent update retry exhausted'
  log 'concurrent update; retrying once'
done
