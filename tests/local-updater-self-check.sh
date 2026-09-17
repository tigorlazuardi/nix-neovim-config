#!/usr/bin/env bash
set -Eeuo pipefail
trap 'printf "self-check failed at line %s: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR

runner=${RUNNER:-scripts/local-update.sh}
prompt=${PROMPT:-scripts/local-update-recovery.md}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
remote=$tmp/remote.git
seed=$tmp/seed
mkdir -p "$seed/scripts" "$tmp/bin"
git init -q --bare "$remote"
git init -q -b main "$seed"
git -C "$seed" config user.name fixture
git -C "$seed" config user.email fixture@example.invalid
printf '#!%s\n' "$BASH" >"$seed/scripts/daily-update.sh"
cat >>"$seed/scripts/daily-update.sh" <<'FIXTURE'
set -u
printf '%s\n' update >>"$TEST_EVENTS"
printf '%s\n' RAW_OUTPUT_MUST_STAY_PRIVATE
if [ -e infra-input ]; then exit 1; fi
if [ -e fail-input ]; then
  if [ "${DAILY_UPDATE_RECOVERY:-0}" = 1 ] && grep -Eq '"version": (9|10)' nvim/lazyvim.json; then
    git rm -q fail-input
    git add nvim/lazyvim.json
    git -c user.name=fixture -c user.email=fixture@example.invalid commit -qm repair
    git push -q origin HEAD:main
    exit 0
  fi
  mkdir -p "$DAILY_UPDATE_EVIDENCE_DIR"
  printf '{"classification":"local-semantic","reason":"fixture"}\n' >"$DAILY_UPDATE_EVIDENCE_DIR/failure.json"
  printf '{}\n' >"$DAILY_UPDATE_EVIDENCE_DIR/flake.lock"
  printf '{}\n' >"$DAILY_UPDATE_EVIDENCE_DIR/lazy-lock.json"
  exit 10
fi
FIXTURE
chmod +x "$seed/scripts/daily-update.sh"
printf '%s\n' original >"$seed/home.nix"
mkdir -p "$seed/nvim"
{
  printf '{"extras":[],"install_version":8,"news":"'
  head -c 140000 /dev/zero | tr '\0' x
  printf '","version": 8}\n'
} >"$seed/nvim/lazyvim.json"
git -C "$seed" add scripts/daily-update.sh home.nix nvim/lazyvim.json
git -C "$seed" commit -qm fixture
git -C "$seed" remote add origin "$remote"
git -C "$seed" push -q -u origin main
git --git-dir="$remote" symbolic-ref HEAD refs/heads/main
sed "s|git@github.com:tigorlazuardi/nix-neovim-config.git|$remote|" "$runner" >"$tmp/local-update.sh"
chmod +x "$tmp/local-update.sh"

printf '#!%s\n' "$BASH" >"$tmp/bin/pi"
cat >>"$tmp/bin/pi" <<'FIXTURE'
set -euo pipefail
printf '%s\n' pi >>"$TEST_EVENTS"
printf '%s\n' pi >>"$PI_COUNT"
args=" $* "
for required in ' --print ' ' --no-session ' ' --approve ' ' --model openai-codex/gpt-5.6-sol ' ' --thinking high ' ' --no-extensions ' ' --no-skills ' ' --no-prompt-templates ' ' --no-context-files ' ' --no-tools '; do
  case "$args" in *"$required"*) ;; *) exit 2 ;; esac
done
case "$args" in
  *'one-shot data-only compatibility-recovery planner'*'recovery request JSON follows through standard input'*) ;;
  *) exit 2 ;;
esac
request=$(cat)
[ "${#request}" -gt 131072 ]
case "$request" in *'"classification"'*'"evidence"'*'"nvim/lazyvim.json"'*) ;; *) exit 2 ;; esac
case "$(cat "$PI_CODING_AGENT_DIR/auth.json")" in
  *'"token":"initial"'*) printf '{"token":"rotated"}\n' >"$PI_CODING_AGENT_DIR/auth.json" ;;
  *'"token":"rotated"'*) ;;
  *) exit 2 ;;
esac
if [ "${PI_MALICIOUS:-0}" = 1 ]; then
  printf '%s\n' '{"edits":[{"path":"home.nix","oldText":"original","newText":"builtins.readFile /etc/passwd"}]}'
elif grep -q '\\"version\\": 9' <<<"$request"; then
  printf '%s\n' '{"edits":[{"path":"nvim/lazyvim.json","oldText":"\"version\": 9","newText":"\"version\": 10"}]}'
else
  printf '%s\n' '{"edits":[{"path":"nvim/lazyvim.json","oldText":"\"version\": 8","newText":"\"version\": 9"}]}'
fi
FIXTURE
chmod +x "$tmp/bin/pi"

printf '#!%s\n' "$BASH" >"$tmp/bin/bwrap"
cat >>"$tmp/bin/bwrap" <<'FIXTURE'
set -eu
args=("$@")
workspace=
pi_config=
command_index=
for ((i = 0; i < ${#args[@]}; i++)); do
  if [ "${args[$i]}" = --bind ] && [ "${args[$((i + 2))]}" = /workspace ]; then
    workspace=${args[$((i + 1))]}
  elif [ "${args[$i]}" = --bind ] && [ "${args[$((i + 2))]}" = /pi-config ]; then
    pi_config=${args[$((i + 1))]}
  elif [ "${args[$i]}" = -- ]; then
    command_index=$((i + 1))
    break
  fi
done
[ -n "$command_index" ]
if [ -n "$workspace" ]; then cd "$workspace"; fi
[ -n "$pi_config" ] && export PI_CODING_AGENT_DIR=$pi_config
exec "${args[@]:$command_index}"
FIXTURE
chmod +x "$tmp/bin/bwrap"

push_failure() {
  git -C "$seed" fetch -q origin main
  git -C "$seed" reset -q --hard origin/main
  : >"$seed/fail-input"
  git -C "$seed" add fail-input
  git -C "$seed" commit -qm failure
  git -C "$seed" push -q origin main
}

export PATH="$tmp/bin:$PATH"
export LOCAL_UPDATE_RECOVERY_PROMPT
LOCAL_UPDATE_RECOVERY_PROMPT=$(realpath "$prompt")
export LOCAL_UPDATE_DAILY_RUNNER="$tmp/trusted-daily-update.sh"
cp "$seed/scripts/daily-update.sh" "$LOCAL_UPDATE_DAILY_RUNNER"
chmod +x "$LOCAL_UPDATE_DAILY_RUNNER"
export LOCAL_UPDATE_SANDBOX_RUNNER="$tmp/bin/bwrap"
export PI_CODING_AGENT_DIR="$tmp/pi-config"
mkdir -p "$PI_CODING_AGENT_DIR"
printf '{"token":"initial"}\n' >"$PI_CODING_AGENT_DIR/auth.json"
export PI_COUNT="$tmp/pi-count"

# Successful deterministic execution never invokes Pi and keeps raw output private.
export LOCAL_UPDATE_STATE_DIR="$tmp/success-state" TEST_EVENTS="$tmp/success-events"
if ! success_output=$(bash "$tmp/local-update.sh"); then
  printf '%s\n' "$success_output" >&2
  cat "$LOCAL_UPDATE_STATE_DIR/run.log" >&2
  exit 1
fi
[ "$(cat "$TEST_EVENTS")" = update ]
[ ! -e "$PI_COUNT" ]
case "$success_output" in *RAW_OUTPUT_MUST_STAY_PRIVATE*) exit 1 ;; esac
case "$success_output" in *'final status: 0'*) ;; *) exit 1 ;; esac
[ "$(stat -c %a "$LOCAL_UPDATE_STATE_DIR/run.log")" = 600 ]

# A tracked failure invokes Pi once; pushed repair is verified from a clean checkout.
push_failure
: >"$PI_COUNT"
export LOCAL_UPDATE_STATE_DIR="$tmp/recovery-state" TEST_EVENTS="$tmp/recovery-events"
recovery_output=$(bash "$tmp/local-update.sh")
[ "$(cat "$TEST_EVENTS")" = $'update\nupdate\npi\nupdate\nupdate' ]
[ "$(wc -l <"$PI_COUNT")" -eq 1 ]
[ ! -e "$LOCAL_UPDATE_STATE_DIR/repository/fail-input" ]
[ "$(git --git-dir="$remote" show main:nvim/lazyvim.json | grep -o '"version": 9')" = '"version": 9' ]
[ "$(git --git-dir="$remote" show main:home.nix)" = original ]
[ "$(git --git-dir="$remote" log -1 --format=%s main)" = repair ]
case "$recovery_output" in *RAW_OUTPUT_MUST_STAY_PRIVATE*) exit 1 ;; esac

# Executable model output is rejected before validation or publication.
git -C "$seed" fetch -q origin main
git -C "$seed" reset -q --hard origin/main
: >"$seed/fail-input"
git -C "$seed" add fail-input
git -C "$seed" commit -qm rejected-recovery
git -C "$seed" push -q origin main
rejected_head=$(git --git-dir="$remote" rev-parse main)
export LOCAL_UPDATE_STATE_DIR="$tmp/rejected-state" TEST_EVENTS="$tmp/rejected-events" PI_MALICIOUS=1
if bash "$tmp/local-update.sh" >/dev/null; then exit 1; fi
unset PI_MALICIOUS
[ "$(git --git-dir="$remote" rev-parse main)" = "$rejected_head" ]
[ "$(git --git-dir="$remote" show main:home.nix)" = original ]
[ "$(cat "$LOCAL_UPDATE_STATE_DIR/recovery-pi-config/auth.json")" = '{"token":"rotated"}' ]

# The next recovery reuses the rotated credential instead of stale user auth.
bash "$tmp/local-update.sh" >/dev/null
[ "$(git --git-dir="$remote" show main:nvim/lazyvim.json | grep -o '"version": 10')" = '"version": 10' ]
[ "$(cat "$LOCAL_UPDATE_STATE_DIR/recovery-pi-config/auth.json")" = '{"token":"rotated"}' ]

# Operational failures stop without invoking Pi.
git -C "$seed" fetch -q origin main
git -C "$seed" reset -q --hard origin/main
: >"$seed/infra-input"
git -C "$seed" add infra-input
git -C "$seed" commit -qm infrastructure-failure
git -C "$seed" push -q origin main
: >"$PI_COUNT"
export LOCAL_UPDATE_STATE_DIR="$tmp/infra-state" TEST_EVENTS="$tmp/infra-events"
if bash "$tmp/local-update.sh" >/dev/null; then exit 1; fi
[ ! -s "$PI_COUNT" ]
[ "$(cat "$TEST_EVENTS")" = update ]

# An active lock skips without touching a checkout.
export LOCAL_UPDATE_STATE_DIR="$tmp/locked-state" TEST_EVENTS="$tmp/locked-events"
mkdir -p "$LOCAL_UPDATE_STATE_DIR"
printf '%s\n' nix-neovim-config-local-updater-v1 >"$LOCAL_UPDATE_STATE_DIR/owner"
exec 8>"$LOCAL_UPDATE_STATE_DIR/update.lock"
flock -n 8
bash "$tmp/local-update.sh" | grep -F 'lock skipped'
[ ! -e "$LOCAL_UPDATE_STATE_DIR/repository" ]
flock -u 8

# Existing unmarked state and changed managed-clone remotes fail closed.
export LOCAL_UPDATE_STATE_DIR="$tmp/unmarked-state"
mkdir -p "$LOCAL_UPDATE_STATE_DIR/repository"
if bash "$tmp/local-update.sh" >/dev/null; then exit 1; fi
export LOCAL_UPDATE_STATE_DIR="$tmp/recovery-state"
git -C "$LOCAL_UPDATE_STATE_DIR/repository" remote set-url origin "$tmp/other.git"
if bash "$tmp/local-update.sh" >/dev/null; then exit 1; fi

# Alternate core.worktree is rejected before reset/clean can touch external data.
export LOCAL_UPDATE_STATE_DIR="$tmp/worktree-state"
mkdir -p "$LOCAL_UPDATE_STATE_DIR"
printf '%s\n' nix-neovim-config-local-updater-v1 >"$LOCAL_UPDATE_STATE_DIR/owner"
git clone -q "$remote" "$LOCAL_UPDATE_STATE_DIR/repository"
mkdir -p "$tmp/external-worktree"
printf '%s\n' preserve >"$tmp/external-worktree/sentinel"
git --git-dir="$LOCAL_UPDATE_STATE_DIR/repository/.git" config core.worktree "$tmp/external-worktree"
if bash "$tmp/local-update.sh" >/dev/null; then exit 1; fi
[ "$(cat "$tmp/external-worktree/sentinel")" = preserve ]
