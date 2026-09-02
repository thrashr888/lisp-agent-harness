# Lisp Agent Harness

An executable spike for a tiny agent harness whose behavior is a live Guile
image. The permanent runtime owns authority, provider transport, tool execution,
and atomic generation switching; the user-owned Scheme image defines the agent.

This is intentionally not a production coding agent yet. The first question is
whether changing agent behavior *inside a running session* feels materially
better than editing and restarting a conventional extension.

## Try the live loop

Requirements: Guile 3.0 and [Ollama](https://docs.ollama.com/). The checked-in
image defaults to the locally installed, tool-capable `qwen3.8:27b-mlx` model at
Ollama's native `http://127.0.0.1:11434/api/chat` endpoint.

```sh
make test
./bin/lisp-agent
```

At the prompt:

```text
live-agent> hello
thinking> ...reasoning streams here...
assistant> ...answer streams here...

live-agent> /eval (define agent-system-prompt "Reply in uppercase.")
generation 2 ...

live-agent> hello
...response using the patched prompt...

live-agent> /rollback
generation 1 ...

live-agent> hello
...response using the restored prompt...
```

Edit `agent/default.scm` and enter `/reload` to load the file as another atomic
generation. `/reload-clean` intentionally drops session patches.

The agent has the same constrained mechanism as the user. For example, ask:

```text
live-agent> Update your prompt so you remember my name is Paul.
```

It calls `live_eval` with Scheme such as `(set! agent-system-prompt ...)` and
activates a validated generation for the next turn. It does not need to rewrite
its source through a shell. Failed patches leave the current generation intact,
and `/rollback` undoes a successful one.

## Ollama default

Start Ollama, confirm the model is installed, and run the harness:

```sh
ollama list
./bin/lisp-agent
```

The selected default advertises completion, tool calling, thinking, vision, and
a 262K context window in the local Ollama metadata. It was chosen over the
104 GB `qwen3.8-flash-next:125b-mlx` model to keep interactive iteration
practical. The live harness has been exercised end to end with this model making
a `read` tool call and incorporating the result.

Native Ollama output streams by default. `agent-thinking` may be `#t`, `#f`, or
the model-specific levels `'low`, `'medium`, and `'high`; `agent-stream?`
controls streaming. All are live:

```text
/eval (define agent-model "your-model-id")
/eval (define agent-thinking 'medium)
/eval (define agent-stream? #f)
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

The model can call `read`, `shell`, and `live_eval`. Reads are canonicalized and
restricted to the process working directory. Shell commands require an explicit
confirmation for every call; the live image can tighten that policy to `deny`,
but cannot set ambient `allow`. `live_eval` can only use the curated Scheme
surface and cannot introduce process, filesystem, network, dynamic-loading, or
ambient evaluation authority.

## Traces and Phoenix

Every completed turn writes OpenInference-shaped `AGENT`, `LLM`, and `TOOL`
spans to `.lisp-agent/traces.jsonl`. They include hierarchy, generation and turn
IDs, model name, bounded inputs/outputs/thinking, duration, status, and Ollama
token counts. This is separate from the append-only audit journal at
`.lisp-agent/events.scm-log`.

Enter `/traces` for a quick local summary. For a full trace UI, start the
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

Open `http://localhost:6006` and select the `lisp-agent-harness` project. The
small Python bridge is dependency-isolated by `uv` and sends OTLP/HTTP protobuf
to Phoenix asynchronously; tracing is still fully functional as local JSONL
when it is absent. `make run-traced` fails fast if local Phoenix is not healthy.
Set `LISP_AGENT_OTEL_ENDPOINT` or `PHOENIX_COLLECTOR_ENDPOINT` to export to a
different collector.

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
- Hard authority validation (`agent-shell-policy` may be `deny` or `ask`, never
  ambient `allow`)

The live image provides:

- Agent name, model selection, and system prompt
- Provider, base URL, API-key environment-variable name, streaming, and thinking
- Enabled tool names
- Maximum tool-call rounds
- User-input transformation and demo behavior
- Shell policy within the authority ceiling

Each request stays pinned to the generation that began it. New code activates
only between requests. Failed evaluations leave the active generation intact.

## Layout

```text
agent/default.scm             live user-owned image
src/live-agent/generation.scm isolated module generations
src/live-agent/runtime.scm    transitions, rollback, journal
src/live-agent/provider.scm   native Ollama and Chat Completions adapters
src/live-agent/trace.scm      JSONL spans and optional OTLP bridge
src/live-agent/tools.scm      stable capability checks
src/live-agent/json.scm       dependency-free JSON codec
src/live-agent/main.scm       interactive shell
test/*.scm                    runtime, provider, JSON, and tool tests
```

Journal and trace attribute values larger than 4 KiB are truncated. Tool output
is bounded at 64 KiB; larger artifacts should be externalized and referenced.

## Next proof

Run a real coding session and change prompt construction or tool selection after
observing a failure. The project is only interesting if that intervention is
more legible and useful than editing and restarting a conventional extension.

## License

[MIT](LICENSE) © 2026 Paul Thrasher.
