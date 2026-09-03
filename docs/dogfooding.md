# Dogfooding the harness inside itself

The harness can now do useful work on its own repository without pretending it
is ready to replace a mature coding agent. The safe shape is a two-level loop:

1. Codex or the user is the supervisor and starts a durable `dogfood` session.
2. The inner agent uses `read`, `rg`, `write`, and exact `edit` inside this repo.
3. Shell still pauses for an explicit one-key approval.
4. Live-image changes are validated and hot-activate for the next turn.
5. Stable-runtime changes are only file edits. They do not enter the running
   authority boundary; the supervisor reviews the diff, runs `make check`, and
   restarts or resumes the session against the candidate runtime.
6. A useful behavioral repair can be exported as a disabled extension before it
   is promoted into reviewed source.

Start directly:

```sh
make dogfood
```

Or, from Codex, use the project MCP tools to start session `dogfood` in `auto`
mode, send a task, inspect its output, handle approvals explicitly, and resume
the same name after a restart. Multiple named sessions can test different live
prompts or models concurrently without mixing conversations or trace identity.

## A sensible first task

Ask the inner agent to inspect one small, testable seam—for example, add a
session-corruption test or improve one exact error message. Require it to name
the files it read, explain the proposed change, use `edit` rather than shell for
the source mutation, and stop after the edit. The outer supervisor then inspects
the diff and runs the tests. This exercises the actual product loop without
granting the inner model authority to accept its own runtime changes.

## What still blocks primary-agent use

- There is no first-class diff, patch-hunk, git-status, diagnostics, or test tool;
  those actions currently fall back to approval-gated shell.
- Long sessions have a hard checkpoint bound but no token budgeting, compaction,
  summarization, or branch/fork model.
- An interrupted tool approval is journaled but not resumable as an outstanding
  operation; the user must retry the turn.
- There is no cancel/interrupt control, background job model, provider retry,
  model fallback, or concurrent tool execution.
- Stable-runtime upgrades need the versioned supervisor/handoff described in
  `docs/live-updates.md`; only the user-owned live image updates in process.
- The Scheme evaluator and filesystem confinement need deeper adversarial tests,
  resource limits, secret redaction, and cross-platform validation.
- Durable checkpoints are local and gitignored under `.lisp-agent/`, with no
  built-in export or share workflow yet.

The milestone for broader dogfooding is not feature parity with Pi. It is being
able to complete a small repository change, resume after a restart, show the
generation and trace lineage, and let an external reviewer accept or reject the
diff without hidden state.
