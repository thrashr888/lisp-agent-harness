(use-modules (srfi srfi-64)
             (live-agent json)
             (live-agent trace))

(test-begin "trace")

(define test-root
  (string-append "/tmp/lisp-agent-trace-test-" (number->string (getpid))))
(system* "mkdir" "-p" test-root)

(define tracer (make-tracer test-root #f))
(define root
  (trace-start! tracer "agent.turn" "AGENT" '((input.value . "hello"))))
(define child
  (trace-start! tracer "ollama.chat" "LLM" '((llm.model_name . "fixture")) root))

(trace-end! child "OK" '((output.value . "hi")))
(trace-end! root "OK" '((output.value . "hi")))

(define lines (trace-tail tracer 10))
(test-equal "writes both completed spans" 2 (length lines))

(define child-json (json-read (car lines)))
(define root-json (json-read (cadr lines)))
(test-equal "child keeps its OpenInference kind"
  "LLM"
  (json-object-ref child-json "kind"))
(test-equal "root finishes after its children"
  "AGENT"
  (json-object-ref root-json "kind"))
(test-equal "child points at root"
  (json-object-ref root-json "span_id")
  (json-object-ref child-json "parent_span_id"))

(trace-close! tracer)
(test-end "trace")
