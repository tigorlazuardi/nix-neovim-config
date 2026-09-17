#!/usr/bin/env bash
set -Eeuo pipefail
trap 'printf "daily updater self-check failed at line %s: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR

runner=${RUNNER:-scripts/daily-update.sh}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
real_git=$(command -v git)
remote=$tmp/remote.git
seed=$tmp/seed
mkdir -p "$seed/scripts" "$seed/nvim/lua/plugins" "$tmp/bin"
cp "$runner" "$seed/scripts/daily-update.sh"
chmod +x "$seed/scripts/daily-update.sh"
printf '{"nodes":{},"root":"root","version":7}\n' >"$seed/flake.lock"
printf '{"plugin":{"branch":"main","commit":"old"}}\n' >"$seed/nvim/lazy-lock.json"
printf 'return {{ "mason-org/mason.nvim", enabled = false }, { "mason-org/mason-lspconfig.nvim", enabled = false }}\n' \
  >"$seed/nvim/lua/plugins/mason.lua"
printf 'return {}\n' >"$seed/nvim/init.lua"
git init -q --bare "$remote"
git init -q -b main "$seed"
git -C "$seed" config user.name fixture
git -C "$seed" config user.email fixture@example.invalid
git -C "$seed" add .
git -C "$seed" commit -qm fixture
git -C "$seed" remote add origin "$remote"
git -C "$seed" push -q -u origin main
git --git-dir="$remote" symbolic-ref HEAD refs/heads/main

printf '#!%s\n' "$BASH" >"$tmp/bin/nix"
cat >>"$tmp/bin/nix" <<'FIXTURE'
set -eu
case "$1 $2" in
  'flake update')
    printf '%s\n' flake-update >>"$TEST_EVENTS"
    [ "${FLAKE_FAIL:-0}" = 0 ] || exit 1
    if [ "${FLAKE_CHANGE:-0}" = 1 ]; then
      printf '{"nodes":{"changed":{}},"root":"root","version":7}\n' >flake.lock
    fi
    ;;
  'flake check')
    if [ "${3:-}" = --no-build ]; then
      printf '%s\n' flake-eval >>"$TEST_EVENTS"
      [ "${EVAL_FAIL:-0}" = 0 ] || exit 1
    else
      printf '%s\n' flake-check >>"$TEST_EVENTS"
      [ "${CHECK_FAIL:-0}" = 0 ] || exit 1
    fi
    ;;
  *) exit 2 ;;
esac
FIXTURE
chmod +x "$tmp/bin/nix"

printf '#!%s\n' "$BASH" >"$tmp/bin/nvim"
cat >>"$tmp/bin/nvim" <<'FIXTURE'
set -eu
printf '%s\n' nvim >>"$TEST_EVENTS"
for isolated_path in "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME" "$XDG_STATE_HOME" "$HOME"; do
  case "$isolated_path" in
    *nix-neovim-lazy-update*) ;;
    *) exit 2 ;;
  esac
done
grep -Fq '"mason-org/mason.nvim", enabled = false' "$XDG_CONFIG_HOME/nvim/lua/plugins/mason.lua"
grep -Fq '"mason-org/mason-lspconfig.nvim", enabled = false' "$XDG_CONFIG_HOME/nvim/lua/plugins/mason.lua"
case " $* " in
  *' +Lazy! update '*)
    [ "${LAZY_FAIL:-0}" = 0 ] || exit 1
    if [ "${LAZY_INVALID:-0}" = 1 ]; then
      printf '[]\n' >"$XDG_CONFIG_HOME/nvim/lazy-lock.json"
    elif [ "${LAZY_ALT:-0}" = 1 ]; then
      printf '{"plugin":{"branch":"main","commit":"newer"}}\n' >"$XDG_CONFIG_HOME/nvim/lazy-lock.json"
    elif [ "${LAZY_CHANGE:-0}" = 1 ]; then
      printf '{"plugin":{"branch":"main","commit":"new"}}\n' >"$XDG_CONFIG_HOME/nvim/lazy-lock.json"
    fi
    ;;
  *"p['mason.nvim'] == nil and p['mason-lspconfig.nvim'] == nil"*"Mason must stay disabled"*) ;;
  *) exit 2 ;;
esac
FIXTURE
chmod +x "$tmp/bin/nvim"

new_checkout() {
  local name=$1
  local checkout=$tmp/$name
  git clone -q "$remote" "$checkout"
  git -C "$checkout" config user.name fixture
  git -C "$checkout" config user.email fixture@example.invalid
  printf '%s\n' "$checkout"
}

export PATH="$tmp/bin:$PATH"
export DAILY_UPDATE_EVIDENCE_DIR=$tmp/evidence

# No-change runs both generators and validation without publishing.
checkout=$(new_checkout no-change)
export TEST_EVENTS=$tmp/no-change-events
before=$(git --git-dir="$remote" rev-parse main)
(cd "$checkout" && bash ./scripts/daily-update.sh >/dev/null)
[ "$(git --git-dir="$remote" rev-parse main)" = "$before" ]
[ "$(cat "$TEST_EVENTS")" = $'flake-update\nnvim\nnvim\nflake-eval\nflake-check' ]

# A change to only one lock is valid and publishes one atomic dependency commit.
checkout=$(new_checkout lazy-change)
export TEST_EVENTS=$tmp/lazy-change-events LAZY_CHANGE=1
(cd "$checkout" && bash ./scripts/daily-update.sh >/dev/null)
unset LAZY_CHANGE
[ "$(git --git-dir="$remote" show main:nvim/lazy-lock.json)" = '{"plugin":{"branch":"main","commit":"new"}}' ]
[ "$(git --git-dir="$remote" show main:flake.lock)" = '{"nodes":{},"root":"root","version":7}' ]
[ "$(git --git-dir="$remote" log -1 --format=%s main)" = 'chore(deps): update Nix and Neovim dependencies' ]

# Network-like generator failures are operational and never push partial locks.
checkout=$(new_checkout lazy-failure)
export TEST_EVENTS=$tmp/lazy-failure-events FLAKE_CHANGE=1 LAZY_FAIL=1
before=$(git --git-dir="$remote" rev-parse main)
if (cd "$checkout" && bash ./scripts/daily-update.sh >/dev/null); then status=0; else status=$?; fi
unset FLAKE_CHANGE LAZY_FAIL
[ "$status" -eq 1 ]
[ "$(git --git-dir="$remote" rev-parse main)" = "$before" ]

# Invalid generated content is recoverable, but remains unpublished.
checkout=$(new_checkout invalid-content)
export TEST_EVENTS=$tmp/invalid-content-events FLAKE_CHANGE=1 LAZY_INVALID=1
before=$(git --git-dir="$remote" rev-parse main)
if (cd "$checkout" && bash ./scripts/daily-update.sh >/dev/null); then status=0; else status=$?; fi
unset FLAKE_CHANGE LAZY_INVALID
[ "$status" -eq 10 ]
[ "$(git --git-dir="$remote" rev-parse main)" = "$before" ]
[ "$(cat "$DAILY_UPDATE_EVIDENCE_DIR/lazy-lock.json")" = '[]' ]

# Recovery mode combines an existing source repair with regenerated locks.
checkout=$(new_checkout recovery)
printf '\n-- repaired\n' >>"$checkout/nvim/init.lua"
export TEST_EVENTS=$tmp/recovery-events FLAKE_CHANGE=1
(cd "$checkout" && DAILY_UPDATE_RECOVERY=1 bash ./scripts/daily-update.sh >/dev/null)
unset FLAKE_CHANGE
[ "$(git --git-dir="$remote" show main:nvim/init.lua | tail -1)" = '-- repaired' ]
[ "$(git --git-dir="$remote" log -1 --format=%s main)" = 'fix(deps): repair automated dependency update' ]

# A server-accepted recovery push with a failed client response is still success.
checkout=$(new_checkout ambiguous-push)
printf '\n-- second repair\n' >>"$checkout/nvim/init.lua"
printf '#!%s\n' "$BASH" >"$tmp/bin/git"
cat >>"$tmp/bin/git" <<'FIXTURE'
set -eu
case " $* " in
  *' push origin HEAD:main '*)
    if [ "${AMBIGUOUS_PUSH:-0}" = 1 ] && [ ! -e "$AMBIGUOUS_MARKER" ]; then
      "$REAL_GIT" "$@"
      : >"$AMBIGUOUS_MARKER"
      exit 1
    fi
    ;;
esac
exec "$REAL_GIT" "$@"
FIXTURE
chmod +x "$tmp/bin/git"
export REAL_GIT="$real_git" AMBIGUOUS_PUSH=1 AMBIGUOUS_MARKER=$tmp/ambiguous-marker
export TEST_EVENTS=$tmp/ambiguous-events LAZY_ALT=1
(cd "$checkout" && DAILY_UPDATE_RECOVERY=1 bash ./scripts/daily-update.sh >/dev/null)
unset AMBIGUOUS_PUSH AMBIGUOUS_MARKER LAZY_ALT
rm "$tmp/bin/git"
[ "$(git --git-dir="$remote" show main:nvim/lazy-lock.json)" = '{"plugin":{"branch":"main","commit":"newer"}}' ]
[ "$(git --git-dir="$remote" show main:nvim/init.lua | tail -1)" = '-- second repair' ]
