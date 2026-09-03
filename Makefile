.PHONY: run dogfood sessions run-traced demo-context demo-context-scripted phoenix phoenix-check phoenix-down phoenix-logs test check

run:
	./bin/lisp-agent

dogfood:
	./bin/lisp-agent --session dogfood

sessions:
	./bin/lisp-agent --list-sessions

run-traced: phoenix-check
	LISP_AGENT_OTEL_ENDPOINT=http://127.0.0.1:6006 ./bin/lisp-agent

demo-context: phoenix-check
	LISP_AGENT_OTEL_ENDPOINT=http://127.0.0.1:6006 ./bin/lisp-agent --agent demo/context-selection/agent.scm --state-dir .lisp-agent/context-demo

demo-context-scripted: phoenix-check
	LISP_AGENT_OTEL_ENDPOINT=http://127.0.0.1:6006 ./bin/lisp-agent --agent demo/context-selection/agent.scm --state-dir .lisp-agent/context-demo < demo/context-selection/session.txt

phoenix:
	docker compose up -d --wait phoenix

phoenix-check:
	curl --fail --silent --show-error --max-time 2 http://127.0.0.1:6006/healthz >/dev/null

phoenix-down:
	docker compose down

phoenix-logs:
	docker compose logs -f phoenix

test:
	GUILE_AUTO_COMPILE=0 guile -L src test/default-agent.scm
	GUILE_AUTO_COMPILE=0 guile -L src test/json.scm
	GUILE_AUTO_COMPILE=0 guile -L src test/provider.scm
	GUILE_AUTO_COMPILE=0 guile -L src test/tools.scm
	GUILE_AUTO_COMPILE=0 guile -L src test/extensions.scm
	GUILE_AUTO_COMPILE=0 guile -L src test/runtime.scm
	GUILE_AUTO_COMPILE=0 guile -L src test/session.scm
	GUILE_AUTO_COMPILE=0 guile -L src test/trace.scm
	python3 test/session_bridge_test.py

check: test
	GUILE_AUTO_COMPILE=0 guild compile -L src -o /tmp/live-agent-generation.go src/live-agent/generation.scm
	GUILE_AUTO_COMPILE=0 guild compile -L src -o /tmp/live-agent-extensions.go src/live-agent/extensions.scm
	GUILE_AUTO_COMPILE=0 guild compile -L src -o /tmp/live-agent-runtime.go src/live-agent/runtime.scm
	GUILE_AUTO_COMPILE=0 guild compile -L src -o /tmp/live-agent-session.go src/live-agent/session.scm
	GUILE_AUTO_COMPILE=0 guild compile -L src -o /tmp/live-agent-json.go src/live-agent/json.scm
	GUILE_AUTO_COMPILE=0 guild compile -L src -o /tmp/live-agent-provider.go src/live-agent/provider.scm
	GUILE_AUTO_COMPILE=0 guild compile -L src -o /tmp/live-agent-tools.go src/live-agent/tools.scm
	GUILE_AUTO_COMPILE=0 guild compile -L src -o /tmp/live-agent-trace.go src/live-agent/trace.scm
	GUILE_AUTO_COMPILE=0 guild compile -L src -o /tmp/live-agent-main.go src/live-agent/main.scm
