#!/usr/bin/env bash
# Deterministic-first updater for an updater-owned clone. Never target an interactive checkout.
set -u -o pipefail
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

readonly repository_url='git@github.com:tigorlazuardi/nix-neovim-config.git'
readonly owner_marker='nix-neovim-config-local-updater-v1'
state_dir=${LOCAL_UPDATE_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/nix-neovim-config-local-update}
repo_dir=$state_dir/repository
marker_file=$state_dir/owner
lock_file=$state_dir/update.lock
private_log=$state_dir/run.log
failure_reason=$state_dir/failure-reason
evidence_dir=$state_dir/recovery-evidence
recovery_pi_config=$state_dir/recovery-pi-config
recovery_bundle=$state_dir/recovery-request.json
recovery_response=$state_dir/recovery-response.json
recovery_workspace=
daily_runner=${LOCAL_UPDATE_DAILY_RUNNER:?LOCAL_UPDATE_DAILY_RUNNER is required}
pi_config_dir=${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}
prompt_file=${LOCAL_UPDATE_RECOVERY_PROMPT:?LOCAL_UPDATE_RECOVERY_PROMPT is required}

journal() { printf 'neovim-update: %s\n' "$1"; }
fail() { journal "failed: $1"; exit 1; }
# shellcheck disable=SC2329 # Called indirectly by the EXIT trap.
finish() {
  local status=$?
  trap - EXIT
  if [ -n "$recovery_workspace" ] && [ -d "$recovery_workspace" ]; then
    rm -rf -- "$recovery_workspace"
  fi
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
  local canonical_repo git_dir top_level worktree_setting origin_urls push_urls
  [ -d "$repo_dir" ] && [ ! -L "$repo_dir" ] || return 1
  [ -d "$repo_dir/.git" ] && [ ! -L "$repo_dir/.git" ] || return 1
  canonical_repo=$(realpath -e "$repo_dir") || return 1
  git_dir=$(git_managed rev-parse --absolute-git-dir 2>>"$private_log") || return 1
  top_level=$(git_managed rev-parse --show-toplevel 2>>"$private_log") || return 1
  [ "$git_dir" = "$canonical_repo/.git" ] && [ "$top_level" = "$canonical_repo" ] || return 1
  worktree_setting=$(git --git-dir="$repo_dir/.git" config --local --get core.worktree 2>>"$private_log" || true)
  [ -z "$worktree_setting" ] || return 1
  origin_urls=$(git --git-dir="$repo_dir/.git" config --local --get-all remote.origin.url 2>>"$private_log") || return 1
  [ "$origin_urls" = "$repository_url" ] || return 1
  push_urls=$(git --git-dir="$repo_dir/.git" config --local --get-all remote.origin.pushurl 2>>"$private_log" || true)
  [ -z "$push_urls" ] || [ "$push_urls" = "$repository_url" ]
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

prepare_recovery_workspace() {
  recovery_workspace=$(mktemp -d "${TMPDIR:-/tmp}/nix-neovim-recovery.XXXXXX") || return 1
  git_managed archive HEAD | tar -x -C "$recovery_workspace" || return 1
  mkdir -p "$recovery_pi_config" || return 1
  chmod 0700 "$recovery_pi_config" || return 1
  if [ ! -f "$recovery_pi_config/auth.json" ] && [ -f "$pi_config_dir/auth.json" ]; then
    install -m 0600 "$pi_config_dir/auth.json" "$recovery_pi_config/auth.json" || return 1
  fi
}

build_recovery_bundle() {
  python3 - "$recovery_workspace" "$evidence_dir" "$failure_classification" "$recovery_bundle" <<'PY'
import json
import pathlib
import sys

workspace = pathlib.Path(sys.argv[1])
evidence = pathlib.Path(sys.argv[2])
classification = sys.argv[3]
output = pathlib.Path(sys.argv[4])
config_path = workspace / "nvim/lazyvim.json"
if not config_path.is_file() or config_path.is_symlink():
    raise SystemExit("repairable LazyVim metadata unavailable")
allowed = [("nvim/lazyvim.json", config_path.read_text(encoding="utf-8"))]
evidence_files = {}
for name in ("failure.json", "flake.lock", "lazy-lock.json"):
    path = evidence / name
    if path.is_file():
        evidence_files[name] = path.read_text(encoding="utf-8")
payload = {
    "classification": classification,
    "evidence": evidence_files,
    "files": dict(sorted(allowed)),
}
encoded = json.dumps(payload, ensure_ascii=False)
if len(encoded.encode()) > 1_500_000:
    raise SystemExit("recovery bundle exceeds size limit")
output.write_text(encoded, encoding="utf-8")
PY
}

apply_recovery_response() {
  python3 - "$recovery_workspace" "$recovery_response" <<'PY'
import json
import pathlib
import sys

workspace = pathlib.Path(sys.argv[1]).resolve()
response = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
if set(response) != {"edits"} or not isinstance(response["edits"], list):
    raise SystemExit("invalid recovery response shape")
if len(response["edits"]) != 1:
    raise SystemExit("recovery requires exactly one data-only edit")
seen = set()
for edit in response["edits"]:
    if set(edit) != {"path", "oldText", "newText"} or not all(isinstance(edit[k], str) for k in edit):
        raise SystemExit("invalid recovery edit")
    rel, old, new = edit["path"], edit["oldText"], edit["newText"]
    if rel in seen or not old or len(new.encode()) > 1_000_000:
        raise SystemExit("unsafe recovery edit")
    if rel != "nvim/lazyvim.json":
        raise SystemExit("only LazyVim metadata may be repaired")
    path = (workspace / rel).resolve()
    if workspace not in path.parents or not path.is_file() or path.is_symlink():
        raise SystemExit("invalid recovery path")
    content = path.read_text(encoding="utf-8")
    if content.count(old) != 1:
        raise SystemExit("recovery oldText must match exactly once")
    repaired = content.replace(old, new, 1)

    def strict_object(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("duplicate JSON key")
            result[key] = value
        return result

    original_data = json.loads(content, object_pairs_hook=strict_object)
    repaired_data = json.loads(repaired, object_pairs_hook=strict_object)
    if not isinstance(original_data, dict) or not isinstance(repaired_data, dict):
        raise SystemExit("LazyVim metadata must remain an object")
    if set(original_data) != set(repaired_data):
        raise SystemExit("LazyVim metadata keys may not change")
    changed = {key for key in original_data if original_data[key] != repaired_data[key]}
    if not changed or not changed <= {"version", "install_version"}:
        raise SystemExit("only LazyVim numeric version metadata may change")
    for key in ("version", "install_version"):
        value = repaired_data.get(key)
        if type(value) is not int or not 1 <= value <= 1000:
            raise SystemExit("invalid LazyVim version metadata")
    path.write_text(repaired, encoding="utf-8")
    seen.add(rel)
PY
}

apply_recovery_workspace() {
  local path tracked_manifest workspace_manifest
  local -a changed_paths=()
  validate_checkout || return 1
  git_managed diff --quiet || return 1
  git_managed diff --cached --quiet || return 1
  [ -z "$(git_managed ls-files --others --exclude-standard)" ] || return 1
  tracked_manifest=$state_dir/recovery-tracked.manifest
  workspace_manifest=$state_dir/recovery-workspace.manifest
  git_managed ls-files -z | sort -z >"$tracked_manifest" || return 1
  (
    cd "$recovery_workspace" &&
      find . \( -type f -o -type l \) -printf '%P\0' | sort -z
  ) >"$workspace_manifest" || return 1
  cmp -s "$tracked_manifest" "$workspace_manifest" || return 1

  while IFS= read -r -d '' path; do
    if [ -L "$repo_dir/$path" ]; then
      [ -L "$recovery_workspace/$path" ] || return 1
      [ "$(readlink "$repo_dir/$path")" = "$(readlink "$recovery_workspace/$path")" ] && continue
    else
      [ -f "$repo_dir/$path" ] && [ -f "$recovery_workspace/$path" ] && [ ! -L "$recovery_workspace/$path" ] \
        || return 1
      cmp -s "$repo_dir/$path" "$recovery_workspace/$path" && continue
    fi
    case "$path" in
      flake.lock | nvim/lazy-lock.json) return 1 ;;
      home.nix | flake.nix | nix/* | nvim/*) ;;
      *) return 1 ;;
    esac
    changed_paths+=("$path")
  done <"$tracked_manifest"
  [ "${#changed_paths[@]}" -gt 0 ] || return 1

  for path in "${changed_paths[@]}"; do
    cp -a --remove-destination "$recovery_workspace/$path" "$repo_dir/$path" || return 1
  done
  validate_checkout || return 1
}

run_deterministic() {
  local recovery=${1:-0} status
  journal 'deterministic update started'
  : >"$failure_reason"
  rm -rf -- "$evidence_dir"
  mkdir -p "$evidence_dir" || return 1
  (
    cd "$repo_dir" && \
      DAILY_UPDATE_RECOVERY="$recovery" \
      DAILY_UPDATE_RESULT_FILE="$failure_reason" \
      DAILY_UPDATE_EVIDENCE_DIR="$evidence_dir" \
      DAILY_UPDATE_RUNNER="$daily_runner" \
      bash "$daily_runner"
  ) >>"$private_log" 2>&1
  status=$?
  if [ "$status" -eq 0 ]; then
    journal 'deterministic update passed'
    return 0
  fi
  journal "deterministic update failed with status $status"
  return "$status"
}

prepare_checkout || fail 'managed checkout preparation failed'
run_deterministic
status=$?
if [ "$status" -eq 0 ]; then
  journal 'completed without recovery'
  exit 0
fi
[ "$status" -eq 10 ] || fail 'operational update failure; recovery skipped'

journal 'content failure reproduction started'
prepare_checkout || fail 'reproduction checkout preparation failed'
run_deterministic
status=$?
if [ "$status" -eq 0 ]; then
  journal 'reproduction passed without recovery'
  exit 0
fi
[ "$status" -eq 10 ] || fail 'reproduction became operational failure; recovery skipped'

failure_classification=$(cat "$failure_reason") || fail 'failure classification unavailable'
prepare_checkout || fail 'recovery checkout preparation failed'
[ -f "$evidence_dir/failure.json" ] || fail 'bounded recovery evidence unavailable'
prepare_recovery_workspace || fail 'recovery workspace preparation failed'
build_recovery_bundle || fail 'recovery request construction failed'
pi_executable=$(command -v pi) || fail 'Pi executable unavailable'
sandbox_runner=${LOCAL_UPDATE_SANDBOX_RUNNER:-bwrap}
# Unset means recovery inherits the user's Pi default provider/model; pinning is opt-in.
recovery_model=${LOCAL_UPDATE_RECOVERY_MODEL:-}
model_args=()
if [ -n "$recovery_model" ]; then
  model_args=(--model "$recovery_model")
fi
journal 'Pi recovery started'
if ! "$sandbox_runner" \
  --die-with-parent --new-session --unshare-all --share-net --cap-drop ALL \
  --ro-bind /nix /nix --ro-bind /etc /etc --proc /proc --dev /dev --tmpfs /tmp \
  --dir /home --dir /home/recovery --dir /workspace \
  --bind "$recovery_pi_config" /pi-config \
  --chdir /workspace --clearenv \
  --setenv HOME /home/recovery \
  --setenv PI_CODING_AGENT_DIR /pi-config \
  --setenv PI_OFFLINE 1 --setenv PI_TELEMETRY 0 \
  -- "$pi_executable" --print --no-session --approve \
    "${model_args[@]}" --thinking high \
    --no-extensions --no-skills --no-prompt-templates --no-context-files --no-tools \
    "$(cat "$prompt_file")

The recovery request JSON follows through standard input." \
  <"$recovery_bundle" >"$recovery_response" 2>>"$private_log"; then
  fail 'Pi recovery failed'
fi
journal 'Pi recovery completed'
apply_recovery_response || fail 'Pi recovery response rejected'
apply_recovery_workspace || fail 'Pi recovery output rejected'

journal 'repaired transaction started'
if ! run_deterministic 1; then
  fail 'repaired transaction failed'
fi

journal 'post-publish verification started'
prepare_checkout || fail 'post-recovery checkout preparation failed'
if run_deterministic; then
  journal 'post-publish verification completed'
  exit 0
fi
journal 'post-publish verification failed'
exit 1
