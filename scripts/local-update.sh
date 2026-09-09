#!/usr/bin/env bash
# Deterministic-first updater for an updater-owned clone. Never target an interactive checkout.
set -u -o pipefail

readonly repository_url='git@github.com:tigorlazuardi/nix-neovim-config.git'
readonly owner_marker='nix-neovim-config-local-updater-v1'
state_dir=${LOCAL_UPDATE_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/nix-neovim-config-local-update}
repo_dir=$state_dir/repository
marker_file=$state_dir/owner
lock_file=$state_dir/update.lock
private_log=$state_dir/run.log
prompt_file=${LOCAL_UPDATE_RECOVERY_PROMPT:?LOCAL_UPDATE_RECOVERY_PROMPT is required}

journal() { printf 'neovim-update: %s\n' "$1"; }
fail() { journal "failed: $1"; exit 1; }
# shellcheck disable=SC2329 # Called indirectly by the EXIT trap.
finish() {
  local status=$?
  trap - EXIT
  journal "final status: $status"
  exit "$status"
}
trap finish EXIT

umask 0077
mkdir -p "$state_dir" || fail 'state directory unavailable'
chmod 0700 "$state_dir" || fail 'state directory permissions unavailable'
exec 9>"$lock_file" || fail 'lock unavailable'
if ! flock -n 9; then
  journal 'lock skipped: another update is active'
  exit 0
fi
journal 'lock acquired'
: >"$private_log"

if [ -e "$marker_file" ]; then
  [ -f "$marker_file" ] && [ ! -L "$marker_file" ] || fail 'invalid ownership marker'
  [ "$(cat "$marker_file")" = "$owner_marker" ] || fail 'ownership marker mismatch'
elif [ -e "$repo_dir" ]; then
  fail 'unmarked checkout exists'
else
  printf '%s\n' "$owner_marker" >"$marker_file" || fail 'ownership marker creation failed'
fi

git_managed() {
  git --git-dir="$repo_dir/.git" --work-tree="$repo_dir" "$@"
}

validate_checkout() {
  local canonical_repo git_dir top_level worktree_setting origin_urls
  [ -d "$repo_dir" ] && [ ! -L "$repo_dir" ] || return 1
  [ -d "$repo_dir/.git" ] && [ ! -L "$repo_dir/.git" ] || return 1
  canonical_repo=$(realpath -e "$repo_dir") || return 1
  git_dir=$(git_managed rev-parse --absolute-git-dir 2>>"$private_log") || return 1
  top_level=$(git_managed rev-parse --show-toplevel 2>>"$private_log") || return 1
  [ "$git_dir" = "$canonical_repo/.git" ] && [ "$top_level" = "$canonical_repo" ] || return 1
  worktree_setting=$(git --git-dir="$repo_dir/.git" config --local --get core.worktree 2>>"$private_log" || true)
  [ -z "$worktree_setting" ] || return 1
  origin_urls=$(git --git-dir="$repo_dir/.git" config --local --get-all remote.origin.url 2>>"$private_log") || return 1
  [ "$origin_urls" = "$repository_url" ]
}

prepare_checkout() {
  if [ ! -e "$repo_dir" ]; then
    journal 'checkout cloning'
    git clone --quiet "$repository_url" "$repo_dir" >>"$private_log" 2>&1 || return 1
  fi
  validate_checkout || return 1
  git_managed fetch --quiet origin main >>"$private_log" 2>&1 || return 1
  git_managed reset --hard origin/main >>"$private_log" 2>&1 || return 1
  git_managed clean -fdx >>"$private_log" 2>&1 || return 1
  journal 'checkout prepared'
}

run_deterministic() {
  journal 'deterministic update started'
  if (cd "$repo_dir" && ./scripts/daily-update.sh) >>"$private_log" 2>&1; then
    journal 'deterministic update passed'
    return 0
  fi
  journal 'deterministic update failed'
  return 1
}

prepare_checkout || fail 'managed checkout preparation failed'
if run_deterministic; then
  journal 'completed without recovery'
  exit 0
fi

journal 'Pi recovery started'
if ! (
  cd "$repo_dir"
  PI_OFFLINE=1 PI_TELEMETRY=0 pi --print --no-session --approve \
    --model openai-codex/gpt-5.6-sol --thinking high \
    --no-extensions --no-skills --no-prompt-templates --no-context-files \
    --tools read,bash,edit,write,grep,find,ls \
    "$(cat "$prompt_file")"
) >>"$private_log" 2>&1; then
  journal 'Pi recovery completed with failure'
else
  journal 'Pi recovery completed'
fi

journal 'verification started'
prepare_checkout || fail 'post-recovery checkout preparation failed'
if run_deterministic; then
  journal 'verification completed'
  exit 0
fi
journal 'verification failed'
exit 1
