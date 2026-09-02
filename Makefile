.PHONY: run run-traced phoenix test check

run:
	./bin/lisp-agent

run-traced:
	LISP_AGENT_OTEL_ENDPOINT=http://127.0.0.1:6006 ./bin/lisp-agent

phoenix:
	uvx --from arize-phoenix phoenix serve

test:
	GUILE_AUTO_COMPILE=0 guile -L src test/default-agent.scm
	GUILE_AUTO_COMPILE=0 guile -L src test/json.scm
	GUILE_AUTO_COMPILE=0 guile -L src test/provider.scm
	GUILE_AUTO_COMPILE=0 guile -L src test/tools.scm
	GUILE_AUTO_COMPILE=0 guile -L src test/runtime.scm
	GUILE_AUTO_COMPILE=0 guile -L src test/trace.scm

check: test
	GUILE_AUTO_COMPILE=0 guild compile -L src -o /tmp/live-agent-generation.go src/live-agent/generation.scm
	GUILE_AUTO_COMPILE=0 guild compile -L src -o /tmp/live-agent-runtime.go src/live-agent/runtime.scm
	GUILE_AUTO_COMPILE=0 guild compile -L src -o /tmp/live-agent-json.go src/live-agent/json.scm
	GUILE_AUTO_COMPILE=0 guild compile -L src -o /tmp/live-agent-provider.go src/live-agent/provider.scm
	GUILE_AUTO_COMPILE=0 guild compile -L src -o /tmp/live-agent-tools.go src/live-agent/tools.scm
	GUILE_AUTO_COMPILE=0 guild compile -L src -o /tmp/live-agent-trace.go src/live-agent/trace.scm
	GUILE_AUTO_COMPILE=0 guild compile -L src -o /tmp/live-agent-main.go src/live-agent/main.scm
