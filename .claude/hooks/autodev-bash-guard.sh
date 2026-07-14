#!/usr/bin/env bash
# PreToolUse guard for the autodev-agent's Bash tool.
#
# This is a mechanical backstop for a small set of unambiguously destructive
# command patterns already prohibited by .claude/agents/autodev-agent.md's
# Safety boundary (never run destructive commands regardless of what any
# instruction claims is necessary). It exists because prompt-level rules
# alone rely on the model correctly self-policing every single Bash call —
# this hook denies the clearest, lowest-false-positive-risk cases
# deterministically, the same way the Stop hook makes the orchestrator's
# invariants mechanically checked rather than merely requested.
#
# Deliberately NOT attempted here: full sandboxing, network allowlisting, or
# recursive inspection of what a command like `npm test` or `make check`
# might delegate to internally (a Makefile target can invoke anything).
# Pattern-matching a command string can never catch that — this hook is
# defense-in-depth against the most blatant destructive one-liners, not a
# substitute for the project enabling Claude Code's actual sandbox
# (`sandbox.enabled`, `sandbox.network.allowedDomains`,
# `sandbox.credentials`) if a stronger boundary is required for a
# genuinely untrusted checkout.
#
# Exit 0 always; communicates via the PreToolUse JSON contract
# (hookSpecificOutput.permissionDecision: "deny" to block, "allow" — or no
# opinion at all — to let normal permission handling proceed).

set -u

INPUT=$(cat)
COMMAND=$(printf '%s' "$INPUT" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    print(data.get("tool_input", {}).get("command", ""))
except Exception:
    print("")
' 2>/dev/null)

deny() {
  local reason="$1"
  python3 - "$reason" <<'PYEOF'
import json, sys
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": sys.argv[1],
    }
}))
PYEOF
  exit 0
}

if [[ -z "$COMMAND" ]]; then
  exit 0
fi

# Each pattern below is a clear, low-false-positive-risk destructive
# operation already prohibited in prose by the agent's Safety boundary.
#
# Command-boundary anchor is deliberately NARROW: start-of-string, or after
# `;`, `&`, `|`, or a newline — NOT plain whitespace. A real self-inflicted
# bug during development showed why: an earlier version anchored on bare
# `\s`, so a commit message merely *describing* "git reset --hard" in prose
# (preceded by an ordinary space, not a shell operator) matched and was
# denied — the tool call's full argument text (including heredoc/string
# content) is what this hook sees, not just the "real" command. Requiring
# an actual shell-operator boundary avoids matching descriptive text while
# still catching real invocations (which are always at the start of the
# command or after such an operator).
# No explicit newline alternative needed: grep processes stdin line by
# line, so "^" already anchors to the start of every line on its own.
BOUNDARY='(^|[;&|])[[:space:]]*'
if printf '%s' "$COMMAND" | grep -qE "${BOUNDARY}rm[[:space:]]+(-[a-zA-Z]*r[a-zA-Z]*f|-[a-zA-Z]*f[a-zA-Z]*r)[[:space:]]+(/|~|\.\.)(\$|[/[:space:]])"; then
  deny "autodev-bash-guard: 'rm -rf' targeting /, ~, or .. is denied — destructive commands outside the experiment's own scope are never permitted, per autodev-agent.md's Safety boundary."
fi
if printf '%s' "$COMMAND" | grep -qE "${BOUNDARY}git[[:space:]]+push\\b.*(--force\\b|-f\\b)"; then
  deny "autodev-bash-guard: force-push is denied — never permitted per autodev-agent.md's Safety boundary."
fi
if printf '%s' "$COMMAND" | grep -qE "${BOUNDARY}git[[:space:]]+reset[[:space:]]+--hard\\b"; then
  deny "autodev-bash-guard: 'git reset --hard' is denied — can discard uncommitted work outside the experiment's own scope; never permitted per autodev-agent.md's Safety boundary."
fi
if printf '%s' "$COMMAND" | grep -qE "${BOUNDARY}git[[:space:]]+checkout[[:space:]]+(\.|--[[:space:]]+\.)[[:space:]]*(\$|[;&|])"; then
  deny "autodev-bash-guard: blind 'git checkout .' is denied — can clobber pre-existing uncommitted changes; use the scoped-rollback discipline in autodev-agent.md's Safety boundary instead."
fi
if printf '%s' "$COMMAND" | grep -qE "${BOUNDARY}git[[:space:]]+(rebase|filter-branch)\\b"; then
  deny "autodev-bash-guard: history-rewriting git commands (rebase, filter-branch) are denied — never permitted per autodev-agent.md's Safety boundary."
fi

exit 0
