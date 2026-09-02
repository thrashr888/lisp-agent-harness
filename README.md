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
`http://127.0.0.1:11434/v1`.

```sh
make test
./bin/lisp-agent
```

At the prompt:

```text
live-agent> hello
...model response...

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

To use another installed Ollama model, redefine it without restarting:

```text
/eval (define agent-model "your-model-id")
```

For a remote OpenAI-compatible provider, also redefine `agent-base-url` and the
name of the environment variable holding its credential:

```text
/eval (define agent-base-url "https://your-provider.example/v1")
/eval (define agent-api-key-environment "OPENAI_API_KEY")
```

Set the environment variable before launching the process. Requests are
currently non-streaming. To exercise live generations without any model, set
`agent-model` to `"demo"`.

The model can call `read` and `shell`. Reads are canonicalized and restricted to
the process working directory. Shell commands require an explicit confirmation
for every call; the live image can tighten that policy to `deny`, but cannot set
ambient `allow`.

## Current boundary

The stable runtime provides:

- Fresh-module evaluation and validation
- Atomic activation and rollback
- An append-only S-expression event journal
- OpenAI-compatible transport and bounded tool output
- A curated live-language interface without process, filesystem, network,
  dynamic-loading, module-resolution, or `eval` functions
- Hard authority validation (`agent-shell-policy` may be `deny` or `ask`, never
  ambient `allow`)

The live image provides:

- Agent name, model selection, and system prompt
- Provider base URL and API-key environment-variable name
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
src/live-agent/provider.scm   Chat Completions adapter
src/live-agent/tools.scm      stable capability checks
src/live-agent/json.scm       dependency-free JSON codec
src/live-agent/main.scm       interactive shell
test/*.scm                    runtime, provider, JSON, and tool tests
```

The journal is written to `.lisp-agent/events.scm-log`. Values larger than 4 KiB
are truncated; a later provider/tool layer should externalize large artifacts
and record stable references.

## Next proof

Run a real coding session and change prompt construction or tool selection after
observing a failure. The project is only interesting if that intervention is
more legible and useful than editing and restarting a conventional extension.
