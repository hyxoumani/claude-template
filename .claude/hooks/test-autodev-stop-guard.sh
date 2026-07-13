#!/usr/bin/env bash
# Regression test harness for autodev-stop-guard.sh.
#
# Builds a series of synthetic .autodev-like directories under a private
# temp root, runs the REAL hook script against each one (with
# CLAUDE_PROJECT_DIR pointed at the synthetic dir, never at this repo),
# and asserts the resulting stdout (JSON decision, or empty on allow) and
# exit code match expectations.
#
# Usage:  .claude/hooks/test-autodev-stop-guard.sh
# Exit code: 0 if all scenarios pass, 1 if any scenario fails.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/autodev-stop-guard.sh"

if [[ ! -x "$HOOK" && ! -f "$HOOK" ]]; then
  echo "FATAL: hook not found at $HOOK" >&2
  exit 1
fi

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/autodev-stop-guard-test.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

pass_count=0
fail_count=0
declare -a failures=()

# ---- scenario scaffolding ---------------------------------------------------

# new_scenario_dir NAME -> prints path to a fresh synthetic project dir
new_scenario_dir() {
  local name="$1"
  local dir="$TMP_ROOT/$name"
  mkdir -p "$dir/.autodev"
  printf '%s' "$dir"
}

# run_hook DIR -> sets globals HOOK_STDOUT, HOOK_EXIT
run_hook() {
  local dir="$1"
  HOOK_STDOUT=$(CLAUDE_PROJECT_DIR="$dir" bash "$HOOK" 2>"$TMP_ROOT/last_stderr")
  HOOK_EXIT=$?
}

# assert_eq LABEL EXPECTED ACTUAL
assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" != "$actual" ]]; then
    echo "    FAIL detail: $label expected [$expected] got [$actual]"
    return 1
  fi
  return 0
}

# assert_contains LABEL HAYSTACK NEEDLE
assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "    FAIL detail: $label expected to contain [$needle], got: $haystack"
    return 1
  fi
  return 0
}

# assert_not_contains LABEL HAYSTACK NEEDLE
assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "    FAIL detail: $label expected NOT to contain [$needle], got: $haystack"
    return 1
  fi
  return 0
}

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

# A canonical ledger with N proposed blocks and one running block whose
# status is 'running'. Extra blocks may be appended via $2.
canonical_ledger() {
  local proposed_count="$1"
  local extra="${2:-}"
  local out=""
  local i
  for ((i = 1; i <= proposed_count; i++)); do
    out+="## Experiment P$i: placeholder hypothesis $i
- status: proposed
Some prose describing the hypothesis.

"
  done
  out+="## Experiment R1: the one running experiment
- status: running
In progress, dispatched to an autodev-agent.

"
  out+="$extra"
  printf '%s' "$out"
}

canonical_paths() {
  cat <<'EOF'
## Avenue A: some active avenue
- status: active
Notes about this avenue.

## Avenue B: an exhausted avenue
- status: exhausted
Notes.
EOF
}

exhausted_paths() {
  cat <<'EOF'
## Avenue A: fully exhausted
- status: exhausted
Nothing left here.

## Avenue B: also exhausted
- status: exhausted
Nothing left here either.
EOF
}

# ---- scenario 1: no ACTIVE -> exit 0, silent -------------------------------
{
  dir=$(new_scenario_dir "01-no-active")
  rm -f "$dir/.autodev/ACTIVE"
  run_hook "$dir"
  ok=0
  assert_eq "exit code" "0" "$HOOK_EXIT" || ok=1
  assert_eq "stdout" "" "$HOOK_STDOUT" || ok=1
  report "no ACTIVE present -> silent allow" "$ok"
}

# ---- scenario 2: ACTIVE present, MODE missing ------------------------------
{
  dir=$(new_scenario_dir "02-mode-missing")
  touch "$dir/.autodev/ACTIVE"
  rm -f "$dir/.autodev/MODE"
  run_hook "$dir"
  ok=0
  assert_eq "exit code" "0" "$HOOK_EXIT" || ok=1
  assert_contains "reason" "$HOOK_STDOUT" "MODE-INVALID" || ok=1
  report "MODE missing -> MODE-INVALID block" "$ok"
}

# ---- scenario 3a: MODE = garbage wrong-case --------------------------------
{
  dir=$(new_scenario_dir "03a-mode-wrong-case")
  touch "$dir/.autodev/ACTIVE"
  printf 'Bounded' > "$dir/.autodev/MODE"
  run_hook "$dir"
  ok=0
  assert_eq "exit code" "0" "$HOOK_EXIT" || ok=1
  assert_contains "reason" "$HOOK_STDOUT" "MODE-INVALID" || ok=1
  report "MODE='Bounded' (wrong case) -> MODE-INVALID" "$ok"
}

# ---- scenario 3b: MODE = garbage with extra trailing content ---------------
{
  dir=$(new_scenario_dir "03b-mode-extra-text")
  touch "$dir/.autodev/ACTIVE"
  printf 'bounded\nextra' > "$dir/.autodev/MODE"
  run_hook "$dir"
  ok=0
  assert_eq "exit code" "0" "$HOOK_EXIT" || ok=1
  assert_contains "reason" "$HOOK_STDOUT" "MODE-INVALID" || ok=1
  report "MODE='bounded\\nextra' -> MODE-INVALID" "$ok"
}

# ---- scenario 4: canonical healthy bounded state -> Invariants hold -------
{
  dir=$(new_scenario_dir "04-healthy-bounded")
  touch "$dir/.autodev/ACTIVE"
  printf 'bounded' > "$dir/.autodev/MODE"
  canonical_ledger 3 > "$dir/.autodev/EXPERIMENTS.md"
  canonical_paths > "$dir/.autodev/PATHS.md"
  run_hook "$dir"
  ok=0
  assert_eq "exit code" "0" "$HOOK_EXIT" || ok=1
  assert_contains "reason" "$HOOK_STDOUT" "Invariants hold" || ok=1
  assert_not_contains "reason" "$HOOK_STDOUT" "VIOLATION" || ok=1
  report "3 proposed + 1 running + 1 active avenue -> Invariants hold, no violations" "$ok"
}

# ---- scenario 5: anchoring — own status wins over prose substring ---------
{
  dir=$(new_scenario_dir "05-anchoring")
  touch "$dir/.autodev/ACTIVE"
  printf 'bounded' > "$dir/.autodev/MODE"
  extra="## Experiment Q1: a proposed block with a misleading note
- status: proposed
Note: an earlier draft of this file mistakenly said 'status: running' here,
but that was corrected; the block's real, own status line above is proposed.

"
  canonical_ledger 3 "$extra" > "$dir/.autodev/EXPERIMENTS.md"
  canonical_paths > "$dir/.autodev/PATHS.md"
  run_hook "$dir"
  ok=0
  assert_eq "exit code" "0" "$HOOK_EXIT" || ok=1
  # Exactly one real running block (R1) exists; the anchoring prose in Q1
  # must NOT be double-counted as a second running block, so this must
  # still read as healthy with no DISPATCH-VIOLATION over-dispatch text.
  assert_contains "reason" "$HOOK_STDOUT" "Invariants hold" || ok=1
  assert_not_contains "reason" "$HOOK_STDOUT" "DISPATCH-VIOLATION" || ok=1
  report "prose containing 'status: running' inside a proposed block is not counted as running" "$ok"
}

# ---- scenario 6: 2 blocks genuinely running -> over-dispatch violation ----
{
  dir=$(new_scenario_dir "06-over-dispatch")
  touch "$dir/.autodev/ACTIVE"
  printf 'bounded' > "$dir/.autodev/MODE"
  extra="## Experiment R2: a second running experiment
- status: running
Also in progress, dispatched simultaneously (this should never happen).

"
  canonical_ledger 3 "$extra" > "$dir/.autodev/EXPERIMENTS.md"
  canonical_paths > "$dir/.autodev/PATHS.md"
  run_hook "$dir"
  ok=0
  assert_eq "exit code" "0" "$HOOK_EXIT" || ok=1
  assert_contains "reason" "$HOOK_STDOUT" "DISPATCH-VIOLATION" || ok=1
  assert_contains "reason" "$HOOK_STDOUT" "2 experiments running simultaneously" || ok=1
  report "2 blocks running -> DISPATCH-VIOLATION (over-dispatch, distinct wording)" "$ok"
}

# ---- scenario 7: 0 blocks running -> under-dispatch violation ------------
{
  dir=$(new_scenario_dir "07-under-dispatch")
  touch "$dir/.autodev/ACTIVE"
  printf 'bounded' > "$dir/.autodev/MODE"
  cat > "$dir/.autodev/EXPERIMENTS.md" <<'EOF'
## Experiment P1: placeholder
- status: proposed
Prose.

## Experiment P2: placeholder
- status: proposed
Prose.

## Experiment P3: placeholder
- status: proposed
Prose.
EOF
  canonical_paths > "$dir/.autodev/PATHS.md"
  run_hook "$dir"
  ok=0
  assert_eq "exit code" "0" "$HOOK_EXIT" || ok=1
  assert_contains "reason" "$HOOK_STDOUT" "DISPATCH-VIOLATION" || ok=1
  assert_contains "reason" "$HOOK_STDOUT" "no experiment has 'status: running'" || ok=1
  report "0 blocks running -> DISPATCH-VIOLATION (under-dispatch, distinct wording)" "$ok"
}

# ---- scenario 8: PATHS.md fully exhausted -> EXPLORATION-VIOLATION -------
{
  dir=$(new_scenario_dir "08-exploration-violation")
  touch "$dir/.autodev/ACTIVE"
  printf 'bounded' > "$dir/.autodev/MODE"
  canonical_ledger 3 > "$dir/.autodev/EXPERIMENTS.md"
  exhausted_paths > "$dir/.autodev/PATHS.md"
  run_hook "$dir"
  ok=0
  assert_eq "exit code" "0" "$HOOK_EXIT" || ok=1
  assert_contains "reason" "$HOOK_STDOUT" "EXPLORATION-VIOLATION" || ok=1
  report "PATHS.md has no unexplored/active avenue -> EXPLORATION-VIOLATION" "$ok"
}

# ---- scenario 9: COMPLETE present but missing markers ---------------------
{
  dir=$(new_scenario_dir "09-complete-missing-markers")
  touch "$dir/.autodev/ACTIVE"
  printf 'bounded' > "$dir/.autodev/MODE"
  canonical_ledger 3 > "$dir/.autodev/EXPERIMENTS.md"
  canonical_paths > "$dir/.autodev/PATHS.md"
  cat > "$dir/.autodev/COMPLETE" <<'EOF'
VERIFICATION: PASS
ACCEPTANCE_CRITERIA: MET
EOF
  run_hook "$dir"
  ok=0
  assert_eq "exit code" "0" "$HOOK_EXIT" || ok=1
  assert_contains "reason" "$HOOK_STDOUT" "COMPLETE-INVALID" || ok=1
  assert_contains "reason" "$HOOK_STDOUT" "RED_TEAM: EMPTY_HANDED" || ok=1
  report "COMPLETE missing RED_TEAM marker -> COMPLETE-INVALID naming it" "$ok"
}

# ---- scenario 10: valid COMPLETE, bounded -> exit 0, ACTIVE removed -------
{
  dir=$(new_scenario_dir "10-valid-complete-bounded")
  touch "$dir/.autodev/ACTIVE"
  printf 'bounded' > "$dir/.autodev/MODE"
  cat > "$dir/.autodev/COMPLETE" <<'EOF'
VERIFICATION: PASS
RED_TEAM: EMPTY_HANDED
ACCEPTANCE_CRITERIA: MET
EOF
  run_hook "$dir"
  ok=0
  assert_eq "exit code" "0" "$HOOK_EXIT" || ok=1
  assert_eq "stdout" "" "$HOOK_STDOUT" || ok=1
  if [[ -f "$dir/.autodev/ACTIVE" ]]; then
    echo "    FAIL detail: ACTIVE still present after valid bounded COMPLETE"
    ok=1
  fi
  report "valid COMPLETE + bounded -> silent exit 0, ACTIVE actually removed" "$ok"
}

# ---- scenario 11: valid COMPLETE, continuous -> blocked, COMPLETE deleted -
{
  dir=$(new_scenario_dir "11-valid-complete-continuous")
  touch "$dir/.autodev/ACTIVE"
  printf 'continuous' > "$dir/.autodev/MODE"
  canonical_ledger 3 > "$dir/.autodev/EXPERIMENTS.md"
  canonical_paths > "$dir/.autodev/PATHS.md"
  cat > "$dir/.autodev/COMPLETE" <<'EOF'
VERIFICATION: PASS
RED_TEAM: EMPTY_HANDED
ACCEPTANCE_CRITERIA: MET
EOF
  run_hook "$dir"
  ok=0
  assert_eq "exit code" "0" "$HOOK_EXIT" || ok=1
  assert_contains "reason" "$HOOK_STDOUT" "COMPLETE-INVALID" || ok=1
  assert_contains "reason" "$HOOK_STDOUT" "continuous" || ok=1
  if [[ -f "$dir/.autodev/COMPLETE" ]]; then
    echo "    FAIL detail: COMPLETE still present after continuous-mode rejection"
    ok=1
  fi
  if [[ ! -f "$dir/.autodev/ACTIVE" ]]; then
    echo "    FAIL detail: ACTIVE was removed even though continuous mode never exits"
    ok=1
  fi
  report "valid COMPLETE + continuous -> COMPLETE-INVALID, COMPLETE deleted, session stays ACTIVE" "$ok"
}

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
