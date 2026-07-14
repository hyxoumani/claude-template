#!/usr/bin/env bash
# Regression test harness for autodev-bash-guard.sh.
#
# Feeds synthetic PreToolUse JSON payloads to the real hook script and
# asserts whether it denies (with a reason) or stays silent (allow).
#
# Usage:  .claude/hooks/test-autodev-bash-guard.sh
# Exit code: 0 if all scenarios pass, 1 if any scenario fails.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/autodev-bash-guard.sh"

if [[ ! -f "$HOOK" ]]; then
  echo "FATAL: hook not found at $HOOK" >&2
  exit 1
fi

pass_count=0
fail_count=0
declare -a failures=()

report() {
  local name="$1" ok="$2"
  if [[ "$ok" -eq 0 ]]; then
    echo "PASS: $name"
    pass_count=$((pass_count + 1))
  else
    echo "FAIL: $name"
    fail_count=$((fail_count + 1))
    failures+=("$name")
  fi
}

# run_command CMD -> sets globals CMD_STDOUT, CMD_EXIT
run_command() {
  local cmd="$1"
  local payload
  payload=$(python3 -c "import json,sys; print(json.dumps({'tool_input': {'command': sys.argv[1]}}))" "$cmd")
  CMD_STDOUT=$(printf '%s' "$payload" | bash "$HOOK")
  CMD_EXIT=$?
}

assert_denied() {
  local name="$1" cmd="$2"
  run_command "$cmd"
  ok=0
  [[ "$CMD_EXIT" -eq 0 ]] || ok=1
  if ! printf '%s' "$CMD_STDOUT" | python3 -c '
import json, sys
d = json.load(sys.stdin)
out = d.get("hookSpecificOutput", {})
assert out.get("permissionDecision") == "deny"
assert isinstance(out.get("permissionDecisionReason"), str) and out["permissionDecisionReason"]
' 2>/dev/null; then
    echo "    FAIL detail: expected a deny decision for: $cmd (got: $CMD_STDOUT)"
    ok=1
  fi
  report "$name" "$ok"
}

assert_allowed() {
  local name="$1" cmd="$2"
  run_command "$cmd"
  ok=0
  [[ "$CMD_EXIT" -eq 0 ]] || ok=1
  [[ -z "$CMD_STDOUT" ]] || { echo "    FAIL detail: expected silent allow for: $cmd (got: $CMD_STDOUT)"; ok=1; }
  report "$name" "$ok"
}

# ---- deny scenarios ---------------------------------------------------------
assert_denied "rm -rf / is denied" "rm -rf /"
assert_denied "rm -rf ~ is denied" "rm -rf ~"
assert_denied "rm -rf .. is denied" "cd foo && rm -rf .."
assert_denied "git push --force is denied" "git push --force origin main"
assert_denied "git push -f is denied" "git push -f origin main"
assert_denied "git reset --hard is denied" "git reset --hard HEAD~1"
assert_denied "blind git checkout . is denied" "git checkout ."
assert_denied "git checkout -- . is denied" "git checkout -- ."
assert_denied "git rebase is denied" "git rebase main"
assert_denied "git filter-branch is denied" "git filter-branch --force"

# ---- allow scenarios (legitimate commands must not be blocked) ------------
assert_allowed "npm test is allowed" "npm test"
assert_allowed "pytest is allowed" "pytest -x"
assert_allowed "scoped rm -rf ./build is allowed" "rm -rf ./build"
assert_allowed "git checkout main (branch switch) is allowed" "git checkout main"
assert_allowed "git checkout -b new-branch is allowed" "git checkout -b new-branch"
assert_allowed "git push (no force) is allowed" "git push origin main"
assert_allowed "git status is allowed" "git status"
assert_allowed "empty command is allowed" ""

# Real, self-inflicted bug found during development: an earlier boundary
# regex anchored on bare whitespace, so a commit message merely describing
# these patterns in prose (mid-sentence, not a real invocation) was denied.
assert_allowed "commit message mentioning denied patterns in prose is allowed" \
  "git commit -m \"denies force-push, rm -rf /, git reset --hard, blind git checkout ., history rewriting\""

# ---- summary ----------------------------------------------------------------
total=$((pass_count + fail_count))
echo ""
echo "===================================================="
echo "$pass_count/$total passed"
if [[ "$fail_count" -gt 0 ]]; then
  echo "FAILED scenarios:"
  for f in "${failures[@]}"; do
    echo "  - $f"
  done
  exit 1
fi
exit 0
