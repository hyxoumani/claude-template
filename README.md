# claude_template — autonomous development template

A Claude Code project template that runs an **enforced autonomous development
loop**: an orchestrator that, quant-firm style, continuously proposes
experiments toward a goal and dispatches worker agents to execute them. In
**bounded** mode it cannot stop until the goal is verifiably complete (or the
user manually aborts it); in **continuous** mode there is no completion
state at all — it never stops on its own, only an explicit `/autodev stop`
or the user interrupting the session ends it.

## Usage

```text
/autodev <goal>     # start a session — the loop runs until genuinely done
/autodev resume     # continue an interrupted session from .autodev/ state
/autodev status     # report session state; only truly "stops" if no session is ACTIVE — otherwise the loop continues right after
/autodev stop       # manual abort (the only sanctioned early exit)
```

## How it works

**Orchestrator** (`.claude/skills/autodev/SKILL.md`) — the PM. Each
iteration it evaluates the last experiment's evidence, keeps or reverts the
work, creatively proposes new experiments, and dispatches exactly one to an
agent. Sequential mode: one experiment in flight at a time (the ledger
format supports parallel dispatch later).

**Worker** (`.claude/agents/autodev-agent.md`) — merged analyst/developer.
Receives one experiment brief, investigates, implements with tests, runs
verification, and reports back with evidence. Never spawns subagents. Full
detail (diffs, command output) goes to `.autodev/reports/<ID>.md`; the
final message the orchestrator actually sees is a contracted, under-150-word
summary (verdict/files/tests/risks) — this is what keeps the orchestrator's
own context from filling up with every agent's full output. A `PreToolUse`
hook (`.claude/hooks/autodev-bash-guard.sh`) mechanically denies a small set
of unambiguously destructive Bash patterns (force-push, `rm -rf /`, `git
reset --hard`, blind `git checkout .`, history rewriting) as defense in
depth — it's not a substitute for a real sandbox if the checkout is
genuinely untrusted, just a backstop beyond prompt-level self-policing.

**Enforcement** (`.claude/hooks/autodev-stop-guard.sh`, registered in
`.claude/settings.json`) — a Stop hook, the same mechanism as Anthropic's
Ralph Wiggum plugin. While `.autodev/ACTIVE` exists, the harness blocks
every attempt by the agent to end its turn — and the hook **audits the
ledger and paths map** on each attempt, naming violations in its block
message: fewer than 3 launchable `proposed` experiments is a
QUEUE-VIOLATION; anything other than exactly 1 `running` experiment (zero
or more than one) is a DISPATCH-VIOLATION; and no `unexplored`/`active`
avenue left in `PATHS.md` is an EXPLORATION-VIOLATION. Parsing is
block-anchored — each ledger/paths entry's own first `- status:` line,
never a raw grep over the whole file. "Always investigating new paths" is
a machine-checked invariant, not an instruction the model can drift from.
When every invariant already holds and `.autodev/RUNNING_SINCE` shows the
one running experiment was dispatched recently (< 30 min), the hook lets
the turn end silently instead of forcing a "keep going" nudge — there's a
genuinely in-flight agent, so waiting for it isn't idling. A missing/stale
`RUNNING_SINCE` still blocks with a stale-dispatch check.

**Goal modes** — at kickoff the goal is classified `bounded` (real finish
line) or `continuous` (open-ended: "keep improving", "maximize X"; the
default when in doubt). In continuous mode self-termination is mechanically
impossible: the hook deletes any `COMPLETE` marker and blocks anyway — only
the user can end the session.

**Completion gate (bounded mode)** — `COMPLETE` may be written only when
every acceptance criterion in `GOAL.md` is met with evidence, full
verification passed in that same iteration, a **red-team review** —
tracked in the ledger as its own `RT-<N>` pseudo-experiment — attacked the
completion claim and came back empty-handed, and a rationale is journaled
— in which "remaining work is blocked on time/data" is never admissible.
`COMPLETE` itself is a structured attestation, not a bare marker: the hook
greps it for three literal lines (`VERIFICATION: PASS`,
`RED_TEAM: EMPTY_HANDED`, `ACCEPTANCE_CRITERIA: MET`) and treats it as
invalid — naming the missing marker(s) — if any is absent. The three
markers are necessary but NOT sufficient by themselves: the hook also
cross-references the live `EXPERIMENTS.md` and requires the
HIGHEST-numbered `RT-<N>` block to have `path: red-team-review` and
`status: validated` — a bare `COMPLETE` with the right marker text but no
real, ledger-tracked, validated red-team review is rejected the same way.

**Safety** — there is deliberately no iteration cap. Note Claude Code
itself defaults to capping consecutive Stop-hook blocks at 8
(`CLAUDE_CODE_STOP_HOOK_BLOCK_CAP`) and would otherwise silently override
this hook and force-terminate the session — `.claude/settings.json` sets
that env var to `"0"` so the "no cap" design actually holds. Manual stops
only: interrupt the session (Esc/Ctrl+C) or run `/autodev stop`.
Runaway-spawn protection is structural — only the orchestrator spawns
agents, one at a time, and agents never spawn agents.

## Session state (`.autodev/`, gitignored)

| File | Purpose |
|---|---|
| `MODE` | `bounded` or `continuous` — decides whether a completion gate exists at all |
| `GOAL.md` | Goal + copied standing rules + acceptance criteria (bounded) or standing obligations (continuous); immutable after kickoff |
| `PATHS.md` | Exploration frontier: every investigation avenue, `unexplored/active/exhausted` (exhausted requires evidence to be cited) |
| `EXPERIMENTS.md` | Ledger: hypothesis, rationale, status, outcome evidence per experiment; audited by the hook |
| `EXPERIMENTS-archive.md` | Concluded (`validated`/`rejected`) blocks relocated out of the live ledger once it grows large — never deleted, just moved; the hook never reads this file |
| `JOURNAL.md` | Append-only iteration log; survives context compaction and crashes |
| `library/` | One brief per concluded experiment (dates, verdict, how it went, lessons); append-only institutional memory that persists across sessions |
| `reports/` | One full-detail report per agent dispatch (`<EXPERIMENT-ID>.md`), written by the agent itself — the one file agents may write under `.autodev/`; the orchestrator reads it only when the contracted summary isn't enough |
| `ACTIVE` | Marker: session in progress — the Stop hook blocks exit while it exists |
| `RUNNING_SINCE` | Unix timestamp of the current dispatch; lets the hook trust an agent is genuinely in flight and allow a quiet turn-end instead of a busywork nudge |
| `COMPLETE` | Written only when the completion gate passes; must contain the three literal marker lines above AND have the highest-numbered `RT-<N>` block in `EXPERIMENTS.md` validated, or the hook treats it as invalid; valid + bounded mode is what lets the hook allow exit |
| `iteration_count` | Blocked-stop counter, logging only |

Because all state is in files, a crashed or closed session loses nothing —
`/autodev resume` picks up exactly where it left off.

## Adapting the template

- Copy `.claude/` (and `.gitignore` entries) into any project.
- Put project-specific verification commands in your `CLAUDE.md` or let the
  orchestrator derive them at kickoff into `GOAL.md`.
- To make enforcement even stricter, extend the stop hook to re-run your
  test command itself and reject a `COMPLETE` written over failing tests.
