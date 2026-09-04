# shift

`shift` is an executable spike for a tiny agent harness whose behavior is a live Guile
image. The permanent runtime owns authority, provider transport, tool execution,
and atomic generation switching; the user-owned Scheme image defines the agent.

This is intentionally not a production coding agent yet. The first question is
whether changing agent behavior *inside a running session* feels materially
better than editing and restarting a conventional extension.

## Try the live loop

Requirements: Guile 3.0, [ripgrep](https://github.com/BurntSushi/ripgrep), and
[Ollama](https://docs.ollama.com/). The checked-in image defaults to the locally
installed, tool-capable `qwen3.8:27b-mlx` model at Ollama's native
`http://127.0.0.1:11434/api/chat` endpoint.

```sh
make test
./bin/shift
./bin/shift "Give me a cookie recipe about Lisp."
```

A quoted positional argument is submitted immediately as the first user turn.
In a terminal the process remains interactive after the answer; with redirected
stdin it exits naturally at end-of-file. The initial turn uses the same tools,
streaming, tracing, approvals, and durable checkpoint path as a typed prompt.

Boot is deliberately compact:

```text
shift λ
  default · generation 1 · 0123456789ab
  qwen3.8:27b-mlx via ollama
  stream on · thinking off · watch on
  8 tools · shell ask · /help for commands
```

At the prompt:

```text
shift> hello
thinking> ...reasoning streams here...
assistant> ...answer streams here...

shift> /eval (define agent-system-prompt "Reply in uppercase.")
generation 2 ...

shift> hello
...response using the patched prompt...

shift> /rollback
generation 1 ...

shift> hello
...response using the restored prompt...
```

Edit `agent/default.scm` while the process is running and the validated file is
automatically activated as another atomic generation. Existing live patches are
retained, and a turn already in flight remains pinned to the generation that
started it. An invalid or incomplete save is rejected once, leaves the working
generation active, and is retried after the file changes again. `/reload` is
still available explicitly; `/reload-clean` intentionally drops session patches.
Pass `--no-watch` to disable automatic source watching.

## Durable named sessions

Use a named session when the conversation and live behavior should survive a
process restart:

```sh
./bin/shift --session dogfood       # resume if present, otherwise create
./bin/shift --session recipes "Continue our Lisp cookie recipe."
./bin/shift --new-session spike-2   # fail if the name already exists
./bin/shift --resume dogfood        # fail if it does not exist
./bin/shift --list-sessions
```

The checkpoint at `.shift/sessions/NAME/session.json` is atomically
rewritten after successful turns and interactive mutations. It stores the
provider message history, next turn number, active live-patch source, generation
number, and a stable session ID. Resume rebuilds a fresh Scheme module from the
current agent source plus those validated patches; it never deserializes a live
Guile object. Traces before and after restart therefore share `session.id` and
`session.name` while retaining the exact generation that produced each result.

`/session` shows the current identity and checkpoint. `/reset` clears the
persisted conversation but intentionally keeps live behavior. The rollback
stack is process-local in this version: the active patch stack resumes, but
older in-memory generations do not. Checkpoints are bounded at 8 MiB and 2,000
messages; large artifacts belong in files with references in the conversation.
An advisory owner lock prevents two processes from opening and overwriting the
same named session concurrently; different names remain fully concurrent.

Older history compacts automatically after 80 provider messages, retaining at
least 24 recent messages and a boundary-safe summary. Both values are live
Scheme settings (`agent-compaction-threshold` and
`agent-compaction-keep-recent`). `/compact` runs the same traced operation on
demand. A failed or cancelled summary leaves the original checkpoint intact.
Compacted turn evidence remains searchable in the session trace with
`/traces QUERY`; `/trace SPAN_ID` retrieves the full stored span behind a hit.

Ctrl-C cancels an in-flight model call, tool call, or compaction and returns to
the prompt without adding the interrupted turn to conversation history. Before
each enabled tool executes, `shift` atomically records its name, arguments, and
generation. If the process dies or a tool is cancelled, the next boot reports
the ambiguous call. `/recover` inspects it, `/recover retry` repeats it only
after an explicit user action, and `/recover discard` clears it without running
anything. `live_eval` and extension mutations are never replayed because their
post-crash state must be inspected instead.

The agent has the same constrained mechanism as the user. For example, ask:

```text
shift> Update your prompt so you remember my name is Paul.
```

It calls `live_eval` with Scheme such as `(set! agent-system-prompt ...)` and
first explains the binding, reason, and expected effect. The tool then reports
the before/after generation IDs and fingerprints; the agent explains that result
before continuing. It does not need to rewrite its source through a shell.
Failed patches leave the current generation intact, and `/rollback` undoes a
successful one.

Live patches are limited to 16 KiB and 64 active patches. Their top-level forms
may only be `define`, `define*`, `set!`, or `begin`, and definitions or
assignments must target `agent-*` or `extension-*` names. They still run in the
curated Scheme module and the complete candidate image must pass validation
before it activates. The provider only sees `live_eval` on turns where the user
expresses explicit change intent (for example “fix,” “update,” “change,” or
“configure”), which blocks unsolicited self-rewrites. This narrows accidental
mutation; it is not a resource or semantic sandbox.

## Persistent extension artifacts

A useful live change can become a named Scheme artifact without rewriting the
base agent image. Artifacts live in `extensions/*.scm`, are disabled when
created or exported, and load through the same validated generation boundary:

```text
/extensions
/extension-create terse (set! agent-system-prompt "Answer in one short paragraph.")
/extension-load terse
/extension-disable terse
/extension-export repaired-session
```

`/extension-enable` is an alias for `/extension-load`. Export collects the
active live patch stack, so it can be loaded again after restarting the
process. The agent can perform the same lifecycle through its `extension` tool:
“save your current live changes as an extension named `repaired-session`.”
Artifacts never auto-load and existing names are never overwritten.

## Memorable demo: repair bad context live

The context-selection demo starts with a deliberately stale selector, lets the
agent repair its own `agent-select-context` Scheme function, and retries without
restarting the process:

```sh
make phoenix
make demo-context
```

Follow the short conversation in `demo/context-selection/session.txt`, or run
it automatically with `make demo-context-scripted`. The first answer comes from
the 2024 runbook in generation 1; the user naturally challenges that source,
and the repaired selector uses the 2026 runbook in generation 2. `/traces` and
Phoenix show both selected paths and exactly which generation produced each
answer. See `demo/context-selection/README.md`.

![Live context selector repaired between generations](docs/assets/context-repair-demo.gif)

## Ollama default

Start Ollama, confirm the model is installed, and run the harness:

```sh
ollama list
./bin/shift
```

The selected default advertises completion, tool calling, thinking, vision, and
a 262K context window in the local Ollama metadata. It was chosen over the
104 GB `qwen3.8-flash-next:125b-mlx` model to keep interactive iteration
practical. The live harness has been exercised end to end with this model making
a `read` tool call and incorporating the result.

Native Ollama output streams by default. Thinking is hidden by default;
`agent-thinking` may be `#t`, `#f`, or
the model-specific levels `'low`, `'medium`, and `'high`; `agent-stream?`
controls streaming. `agent-keep-alive` is sent to Ollama as `keep_alive` and
defaults to `"10m"`, long enough for a normal interactive pause without pinning
the model indefinitely. These are all live Scheme settings:

```text
/thinking
/thinking medium
/thinking off
/stream off
/stream on

/eval (define agent-model "your-model-id")
/eval (define agent-thinking 'medium)
/eval (define agent-stream? #f)
/eval (define agent-keep-alive "30m")
```

For a remote OpenAI-compatible provider, also redefine `agent-base-url` and the
name of the environment variable holding its credential:

```text
/eval (define agent-provider 'openai)
/eval (define agent-base-url "https://your-provider.example/v1")
/eval (define agent-api-key-environment "OPENAI_API_KEY")
```

Set the environment variable before launching the process. The generic
OpenAI-compatible adapter is currently non-streaming. To exercise live
generations without any model, set `agent-model` to `"demo"`.

The model can call `read`, `rg`, `write`, `edit`, `shell`, `traces`,
`live_eval`, and `extension`. The `traces` tool searches the complete local
trace file while retaining only a bounded set of current-session hits. Hits are
compact and carry stable span IDs; an exact `span_id` lookup returns the full
stored span. This lets the agent follow generation decisions and tool evidence
from before compaction without reinserting the whole history. File
operations are canonicalized and restricted to the process
working directory. `rg` invokes ripgrep directly and treats queries literally
by default; its explicit `regex: true` mode is for intentional regular
expressions. `write` replaces a complete
file atomically, and `edit` requires an exact unique match unless `replace_all`
is explicit. Shell commands require a confirmation for every call; the live
image can tighten that policy to `deny`, but cannot set ambient `allow`. In an
interactive terminal the approval consumes one `y` or `N` keystroke immediately,
without waiting for Enter.
`live_eval` can only use the curated Scheme surface and cannot introduce
process, filesystem, network, dynamic-loading, or ambient evaluation authority.

## Attach from Codex

The repository includes a project-scoped MCP server in `.codex/config.toml`.
Open this trusted repository as a Codex project (or restart the Codex task after
pulling the config), then Codex can operate multiple named live harness sessions
through typed tools:

- list, create, resume, inspect, read, prompt, approve, and stop named sessions
- cancel in-flight work; compact history; search/fetch traces; and manage recovery
- set thinking or streaming and apply restricted live Scheme expressions
- append system-prompt guidance for later turns
- list, create, load, disable, and export extensions

Each name maps to an independent child process and durable checkpoint. The
bridge launches the same `bin/shift` under a pseudo-terminal, so it
sees the real streaming output and approval boundaries rather than a parallel
mock implementation. A prompt call returns at either the next `shift>`
prompt or a shell approval; Codex must then call the separate approval tool with
an explicit boolean. That tool is approval-gated in the Codex project config and
refuses input unless a shell request is actually pending. The bridge process
owns running processes, while restart-safe state, journals, and traces live
under `.shift/sessions/NAME`.

Because source watching is enabled by default, Codex can edit the live agent
image with its normal project tools and observe the running process activate
that save. This applies to the live image, not authority-bearing stable runtime
modules. See `docs/live-updates.md` for the boundary and a production release
path.

For the guarded “use the harness to improve the harness” loop, run
`make dogfood` or start the `dogfood` session from Codex. Begin with docs, tests,
or the live image; keep stable-runtime edits under external diff review and
restart validation. See `docs/dogfooding.md` for the concrete loop and remaining
gates.

Run the MCP server directly for protocol debugging with:

```sh
./bin/shift-mcp
```

## Traces and Phoenix

Every completed turn writes OpenInference-shaped `AGENT`, `LLM`, and `TOOL`
spans to `.shift/traces.jsonl`. They include hierarchy, generation and turn
IDs, model name, bounded inputs/outputs/thinking, duration, status, and Ollama
token counts. This is separate from the append-only audit journal at
`.shift/events.scm-log`.

Enter `/traces` for a quick local summary, `/traces deployment` to search all
completed spans in the current session, and `/trace SPAN_ID` to fetch a full
stored span. For a full trace UI, start the
official Phoenix container (requires Docker):

```sh
make phoenix
```

This starts Phoenix in the background, waits for its health check, exposes it at
`http://localhost:6006`, and stores its database in a persistent Docker volume.
Then launch the harness with OTLP export enabled:

```sh
make run-traced
```

Open `http://localhost:6006` and select the `shift` project. The
small Python bridge is dependency-isolated by `uv` and sends OTLP/HTTP protobuf
to Phoenix asynchronously; tracing is still fully functional as local JSONL
when it is absent. `make run-traced` fails fast if local Phoenix is not healthy.
Set `SHIFT_OTEL_ENDPOINT` or `PHOENIX_COLLECTOR_ENDPOINT` to export to a
different collector.

The live image and Codex bridge expose the same two-stage `traces` retrieval.
Search scans the complete JSONL file, filters by stable current-session ID, and
returns at most 50 compact newest-first hits. Exact span lookup returns stored
attributes. This is an inspection surface, not deterministic replay; individual
attributes are still truncated by the trace writer.

Ollama prompt-cache behavior is treated as a measurable optimization. The
system message and persisted history form the request prefix; volatile selected
context comes after that prefix. Normal and mutation-intent turns are separate
tool-schema cache cohorts, and a generation change or compaction is an explicit
cache boundary. LLM spans record the cohort, reusable-prefix size, dynamic
context size, tool count, token counts, and Ollama load/prompt/generation
durations. See [durability and prompt-cache strategy](docs/durability-and-prompt-cache.md).

To inspect Phoenix logs or stop the container without deleting its trace volume:

```sh
make phoenix-logs
make phoenix-down
```

## Current boundary

The stable runtime provides:

- Fresh-module evaluation and validation
- Atomic activation and rollback
- An append-only S-expression event journal plus structured JSONL spans
- Native streaming Ollama transport, OpenAI-compatible fallback, and bounded
  tool output
- A curated live-language interface without process, filesystem, network,
  dynamic-loading, module-resolution, or `eval` functions
- Project-confined read, search, atomic write, and exact-edit capabilities
- Complete-session trace search plus bounded exact-span inspection as a model tool
- Named, non-overwriting Scheme extension artifacts that can be loaded,
  disabled, or exported from active live patches
- Atomic named-session checkpoints with conversation, active patches,
  generation continuity, and stable trace identity
- Boundary-safe model compaction, in-flight cancellation, and explicit
  interrupted-tool retry/discard recovery
- Hard authority validation (`agent-shell-policy` may be `deny` or `ask`, never
  ambient `allow`)

The live image provides:

- Agent name, model selection, and system prompt
- Provider, base URL, API-key environment-variable name, streaming, thinking,
  and Ollama model keep-alive
- Enabled tool names
- Maximum tool-call rounds
- Compaction threshold and recent-message retention
- Context selection, user-input transformation, and demo behavior
- Shell policy within the authority ceiling

Each request stays pinned to the generation that began it. New code can activate
while a request is running without changing that request's pinned generation.
Failed evaluations and invalid watched saves leave the active generation intact.

## Layout

```text
agent/default.scm             live user-owned image
src/live-agent/generation.scm isolated module generations
src/live-agent/runtime.scm    transitions, rollback, journal
src/live-agent/session.scm    durable named-session checkpoints
src/live-agent/compaction.scm boundary-safe history reduction
src/live-agent/recovery.scm   interrupted-tool write-ahead record
src/live-agent/extensions.scm persistent artifact lifecycle
src/live-agent/provider.scm   native Ollama and Chat Completions adapters
src/live-agent/prompt.scm     cache-friendly request assembly and persistence split
src/live-agent/trace.scm      JSONL spans and optional OTLP bridge
src/live-agent/tools.scm      stable capability checks
src/live-agent/json.scm       dependency-free JSON codec
src/live-agent/main.scm       interactive shell
scripts/session_bridge.py     dependency-free MCP-to-live-PTY bridge
bin/shift                     primary interactive entry point
bin/shift-mcp                 project-scoped Codex MCP entry point
.codex/config.toml            local MCP registration for trusted projects
extensions/README.md          artifact contract
test/*                        Scheme runtime tests plus MCP integration test
```

The internal Guile module namespace remains `(live-agent ...)` for now. The old
`bin/lisp-agent` and `bin/lisp-agent-mcp` paths are compatibility shims, and a
pre-existing `.lisp-agent/` directory is used only when `.shift/` does not yet
exist.

Journal and trace attribute values larger than 4 KiB are truncated. Tool output
is bounded at 64 KiB, writes at 256 KiB, and edited source files at 512 KiB;
larger artifacts should be externalized and referenced.

## Gaps versus Pi

This spike is testing a narrower idea than Pi. It now has one concrete advantage
to evaluate—transactional, generation-attributed live behavior—but it lacks most
of the product surface of a mature coding harness. See `docs/gaps-with-pi.md` for
the direct comparison and the gaps on both sides.

## Subagent direction

The proposed next step is to fork a validated live generation and a bounded
session checkpoint into an isolated child, then return trace and extension
references for selective promotion. See [Fork the live
image](docs/subagents.md) for the concrete contract and smallest milestone.

## License

[MIT](LICENSE) © 2026 Paul Thrasher.
