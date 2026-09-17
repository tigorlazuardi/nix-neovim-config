#!/usr/bin/env bash
# Atomically update Nix and Neovim dependency locks in an updater-owned clone.
set -u -o pipefail
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

readonly content_failure=10
readonly recovery_mode=${DAILY_UPDATE_RECOVERY:-0}
readonly concurrency_retry=${DAILY_UPDATE_CONCURRENCY_RETRY:-0}
readonly result_file=${DAILY_UPDATE_RESULT_FILE:-}
readonly evidence_dir=${DAILY_UPDATE_EVIDENCE_DIR:-}
readonly runner=${DAILY_UPDATE_RUNNER:-$(realpath "$0")}
transaction_root=

log() { printf 'daily-update: %s\n' "$1"; }
record_result() {
  [ -z "$result_file" ] || printf '%s\n' "$1" >"$result_file"
}
capture_evidence() {
  local reason=$1 lazy_candidate=${2:-nvim/lazy-lock.json}
  [ -n "$evidence_dir" ] || return 1
  mkdir -p "$evidence_dir" || return 1
  jq -n --arg reason "$reason" '{classification:"local-semantic", reason:$reason}' \
    >"$evidence_dir/failure.json" || return 1
  [ ! -f flake.lock ] || cp flake.lock "$evidence_dir/flake.lock" || return 1
  [ ! -f "$lazy_candidate" ] || cp "$lazy_candidate" "$evidence_dir/lazy-lock.json" || return 1
}
fail() { record_result "operational: $1"; log "failed: $1"; exit 1; }
content_fail() {
  capture_evidence "$1" "${2:-}" || fail 'cannot capture bounded recovery evidence'
  record_result "content: $1"
  log "content failure: $1"
  exit "$content_failure"
}
cleanup() {
  if [ -n "$transaction_root" ] && [ -d "$transaction_root" ]; then
    rm -rf -- "$transaction_root"
  fi
}
trap cleanup EXIT

old_revision=$(git rev-parse HEAD) || fail 'cannot read current revision'

mapfile -t untracked_paths < <(git ls-files --others --exclude-standard)
[ "${#untracked_paths[@]}" -eq 0 ] || fail 'untracked files present'

if [ "$recovery_mode" = 1 ]; then
  git restore --source=HEAD -- flake.lock nvim/lazy-lock.json || fail 'cannot discard agent-edited locks'
  mapfile -t repair_paths < <(git diff --name-only)
  [ "${#repair_paths[@]}" -gt 0 ] || content_fail 'agent produced no tracked source repair'
else
  repair_paths=()
  if ! git diff --quiet || ! git diff --cached --quiet; then
    fail 'checkout is not clean'
  fi
fi

nix flake update || fail 'flake update failed'

transaction_root=$(mktemp -d "${TMPDIR:-/tmp}/nix-neovim-lazy-update.XXXXXX") || fail 'cannot create Lazy transaction directory'
mkdir -p "$transaction_root/config" "$transaction_root/data" "$transaction_root/cache" \
  "$transaction_root/state" "$transaction_root/home" || fail 'cannot prepare Lazy transaction directories'
cp -a nvim "$transaction_root/config/nvim" || fail 'cannot stage Neovim config'

run_nvim() {
  HOME="$transaction_root/home" \
    XDG_CONFIG_HOME="$transaction_root/config" \
    XDG_DATA_HOME="$transaction_root/data" \
    XDG_CACHE_HOME="$transaction_root/cache" \
    XDG_STATE_HOME="$transaction_root/state" \
    nvim --headless "$@"
}

run_nvim '+Lazy! update' +qa || fail 'Lazy plugin update failed'
jq -e 'type == "object"' "$transaction_root/config/nvim/lazy-lock.json" >/dev/null \
  || content_fail 'generated Lazy lock is invalid' "$transaction_root/config/nvim/lazy-lock.json"
cp "$transaction_root/config/nvim/lazy-lock.json" nvim/lazy-lock.json \
  || fail 'cannot apply generated Lazy lock'

jq -e 'type == "object" and has("nodes")' flake.lock >/dev/null || content_fail 'flake lock is invalid'
jq -e 'type == "object"' nvim/lazy-lock.json >/dev/null || content_fail 'Lazy lock is invalid'
run_nvim "+lua local p=require('lazy.core.config').plugins; assert(p['mason.nvim'] == nil and p['mason-lspconfig.nvim'] == nil, 'Mason must stay disabled')" +qa \
  || content_fail 'headless Neovim or Mason invariant failed'
nix flake check --no-build || content_fail 'flake evaluation failed'
nix flake check || fail 'flake build check failed'
git diff --check || content_fail 'whitespace check failed'

declare -A allowed_paths=(
  [flake.lock]=1
  [nvim/lazy-lock.json]=1
)
for path in "${repair_paths[@]}"; do
  allowed_paths["$path"]=1
done
mapfile -t changed_paths < <(
  { git diff --name-only; git diff --cached --name-only; git ls-files --others --exclude-standard; } | sort -u
)
for path in "${changed_paths[@]}"; do
  [ -n "${allowed_paths[$path]:-}" ] || fail "unexpected changed path: $path"
done

if [ "${#changed_paths[@]}" -eq 0 ]; then
  log 'dependencies unchanged; validation passed'
  exit 0
fi

git add -- "${changed_paths[@]}" || fail 'staging failed'
git diff --quiet || fail 'unstaged changes remain'
if [ "$recovery_mode" = 1 ]; then
  commit_message='fix(deps): repair automated dependency update'
else
  commit_message='chore(deps): update Nix and Neovim dependencies'
fi
git -c core.hooksPath=/dev/null -c user.name=nix-neovim-updater \
  -c user.email=nix-neovim-updater@localhost commit -m "$commit_message" || fail 'commit failed'

restart_on_latest_main() {
  [ "$concurrency_retry" = 0 ] || fail 'concurrent update retry exhausted'
  log 'origin advanced; regenerating transaction once'
  if [ "$recovery_mode" = 1 ]; then
    if ! git rebase origin/main; then
      git rebase --abort || true
      fail 'repair rebase failed'
    fi
    git reset origin/main || fail 'cannot reopen rebased repair transaction'
    git restore --source=HEAD -- flake.lock nvim/lazy-lock.json \
      || fail 'cannot discard rebased generated locks'
  else
    git reset --hard origin/main || fail 'cannot reset concurrent transaction'
    git clean -fdx || fail 'cannot clean concurrent transaction'
  fi
  DAILY_UPDATE_CONCURRENCY_RETRY=1 DAILY_UPDATE_RECOVERY="$recovery_mode" \
    DAILY_UPDATE_RESULT_FILE="$result_file" DAILY_UPDATE_RUNNER="$runner" exec bash "$runner"
}

git fetch --quiet origin main || fail 'fetch before push failed'
if [ "$(git rev-parse origin/main)" != "$old_revision" ]; then
  restart_on_latest_main
fi
if ! git -c core.hooksPath=/dev/null push origin HEAD:main; then
  git fetch --quiet origin main || fail 'fetch after rejected push failed'
  if git merge-base --is-ancestor HEAD origin/main; then
    log 'push was accepted despite ambiguous client failure'
    exit 0
  fi
  if [ "$(git rev-parse origin/main)" != "$old_revision" ]; then
    restart_on_latest_main
  fi
  fail 'push failed without remote movement'
fi
log "updated $old_revision to $(git rev-parse HEAD)"
