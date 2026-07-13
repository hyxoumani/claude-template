# claude_template — autonomous development template

A Claude Code project template that runs an **enforced autonomous development
loop**: an orchestrator that, quant-firm style, continuously proposes
experiments toward a goal and dispatches worker agents to execute them — and
that **cannot stop** until the goal is verifiably complete.

## Usage

```
/autodev <goal>     # start a session — the loop runs until genuinely done
/autodev resume     # continue an interrupted session from .autodev/ state
/autodev status     # inspect session state without entering the loop
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
verification, and reports back with evidence. Never spawns subagents.

**Enforcement** (`.claude/hooks/autodev-stop-guard.sh`, registered in
`.claude/settings.json`) — a Stop hook, the same mechanism as Anthropic's
Ralph Wiggum plugin. While `.autodev/ACTIVE` exists, the harness blocks
every attempt by the agent to end its turn — and the hook **audits the
ledger** on each attempt, naming violations in its block message: fewer
than 3 launchable `proposed` experiments is a QUEUE-VIOLATION; zero
`running` is a DISPATCH-VIOLATION. "Always investigating new paths" is a
machine-checked invariant, not an instruction the model can drift from.

**Goal modes** — at kickoff the goal is classified `bounded` (real finish
line) or `continuous` (open-ended: "keep improving", "maximize X"; the
default when in doubt). In continuous mode self-termination is mechanically
impossible: the hook deletes any `COMPLETE` marker and blocks anyway — only
the user can end the session.

**Completion gate (bounded mode)** — `COMPLETE` may be written only when
every acceptance criterion in `GOAL.md` is met with evidence, full
verification passed in that same iteration, a **red-team agent** attacked
the completion claim and came back empty-handed, and a rationale is
journaled — in which "remaining work is blocked on time/data" is never
admissible.

**Safety** — there is deliberately no iteration cap. Manual stops only:
interrupt the session (Esc/Ctrl+C) or run `/autodev stop`. Runaway-spawn
protection is structural — only the orchestrator spawns agents, one at a
time, and agents never spawn agents.

## Session state (`.autodev/`, gitignored)

| File | Purpose |
|---|---|
| `MODE` | `bounded` or `continuous` — decides whether a completion gate exists at all |
| `GOAL.md` | Goal + copied standing rules + acceptance criteria (bounded) or standing obligations (continuous); immutable after kickoff |
| `PATHS.md` | Exploration frontier: every investigation avenue, `unexplored/active/exhausted` (exhausted requires cited evidence) |
| `EXPERIMENTS.md` | Ledger: hypothesis, rationale, status, outcome evidence per experiment; audited by the hook |
| `JOURNAL.md` | Append-only iteration log; survives context compaction and crashes |
| `library/` | One brief per concluded experiment (dates, verdict, how it went, lessons); append-only institutional memory that persists across sessions |
| `ACTIVE` | Marker: session in progress — the Stop hook blocks exit while it exists |
| `COMPLETE` | Written only when the completion gate passes; the hook then allows exit |
| `iteration_count` | Blocked-stop counter, logging only |

Because all state is in files, a crashed or closed session loses nothing —
`/autodev resume` picks up exactly where it left off.

## Adapting the template

- Copy `.claude/` (and `.gitignore` entries) into any project.
- Put project-specific verification commands in your `CLAUDE.md` or let the
  orchestrator derive them at kickoff into `GOAL.md`.
- To make enforcement even stricter, extend the stop hook to re-run your
  test command itself and reject a `COMPLETE` written over failing tests.
