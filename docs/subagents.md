# Fork the live image: a subagent direction for shift

Status: design proposal, not an implemented orchestration API.

The interesting move is not merely to let an agent spawn another chat. `shift`
can fork both conversation state and a validated behavior generation. A child
can then experiment with a prompt, context selector, model route, or extension
inside an isolated branch and return an inspectable artifact rather than
silently changing the parent.

## Proposed child-run contract

A spawn captures this immutable envelope:

- parent session ID, turn, trace ID, generation ID, and fingerprint
- a bounded conversation checkpoint or compacted summary reference
- a snapshot of enabled tools and the stable authority ceiling
- an explicit task plus budget, cancellation token, and join policy

The child gets a new session and trace scope. It may create live patches and
extensions locally, but it cannot widen the parent's capability ceiling. Its
return value is structured:

```text
result              concise answer or patch proposal
trajectory_ref      child session/checkpoint reference
trace_ref           trace ID plus relevant span IDs
generation_ref      child generation and fingerprint
extension_proposal  optional disabled artifact to review/promote
```

This is “fork the live image, not just the conversation.” One subagent can test
a context selector while another keeps the baseline. The parent compares
recorded tool outcomes and evaluator spans, then selectively promotes the
winning extension into a new parent generation. No child code merges merely
because its prose says it worked.

## Trace topology

The root turn owns a `subagent.fanout` scope; each child owns a sibling
`subagent.run` scope; the join is a separate span with links to every child
result. Parent-child span IDs explain ownership, while links represent a real
fan-out/join DAG. Stable marks record spawn, checkpoint, compaction,
cancellation, recovery, and extension promotion.

This follows the useful boundary in [NeMo Relay's scope
model](https://docs.nvidia.com/nemo/relay/about-nemo-relay/concepts/scopes):
scopes own nested work and isolate concurrent context, but the application—not
Relay—still chooses and schedules the agent pattern. `shift` should own that
small orchestrator while keeping scope, middleware, and trace semantics
separable.

The [Trace Engineering
essay](https://x.com/marfinxx/status/2094016175617241109) motivates three
details worth preserving: distinguish the sequential trajectory from the
causal trace, classify side effects before execution, and write a recovery
record before mutating work. Raw traces should remain out of the prompt;
subagents exchange compact summaries and stable references, then use the trace
tool for bounded inspection.

## Smallest credible milestone

1. Add `session-fork PARENT CHILD` that copies a checkpoint and pins the same
   generation fingerprint.
2. Add `subagent.run` and `subagent.join` spans with explicit trace links.
3. Add one supervisor tool that starts a child with a narrower tool list,
   waits or cancels it, and returns only the structured envelope above.
4. Let the child export a disabled extension proposal; require a parent/user
   action to load it.
5. Evaluate baseline versus child with the same fixed checkpoint and a
   deterministic tool-result assertion.

Only then add parallel fan-out. Without isolated checkpoints, cancellation,
write-ahead recovery, and causal trace identity, “subagents” would mostly be
interleaved processes and optimistic text summaries.
