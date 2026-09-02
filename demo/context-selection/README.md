# Live context-selection demo

This demo begins with an intentionally bad Scheme context selector. It chooses
the 2024 Atlas runbook and answers `8080`. The user points out the stale source,
the agent rewrites `agent-select-context` through `live_eval`, and the retry uses
generation 2 plus the 2026 runbook to answer `9443`.

Start Dockerized Phoenix and enter the demo:

```sh
make phoenix
make demo-context
```

Paste the three prompts from `session.txt`, or run the complete script:

```sh
make demo-context-scripted
```

The memorable bit is not merely that the second answer is right. `/traces`
shows the current session's `context.select` RETRIEVER spans, their selected
file paths, and the generation attached to each answer. Phoenix shows the same
trace tree in the `lisp-agent-harness` project at `http://localhost:6006`.
