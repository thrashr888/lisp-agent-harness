(use-modules (ice-9 textual-ports)
             (srfi srfi-64)
             (live-agent generation)
             (live-agent runtime))

(define fixture-source
  (string-append
   "(define agent-name \"fixture\")\n"
   "(define agent-model \"demo\")\n"
   "(define agent-base-url \"http://127.0.0.1:9999/v1\")\n"
   "(define agent-api-key-environment \"OPENAI_API_KEY\")\n"
   "(define agent-max-tool-rounds 2)\n"
   "(define agent-system-prompt \"fixture prompt\")\n"
   "(define agent-tools '(read))\n"
   "(define agent-shell-policy 'deny)\n"
   "(define (agent-transform-user text) text)\n"
   "(define (agent-demo-response text) (string-append \"old: \" (agent-transform-user text)))\n"))

(define test-root
  (string-append "/tmp/lisp-agent-harness-test-" (number->string (getpid))))
(define source-path (string-append test-root "/agent.scm"))
(define state-path (string-append test-root "/state"))

(system* "mkdir" "-p" test-root)
(call-with-output-file source-path
  (lambda (port) (display fixture-source port)))

(test-begin "live runtime")

(define runtime (make-runtime source-path state-path))

(test-equal "starts at generation one"
  1
  (generation-id (runtime-current runtime)))

(test-equal "base behavior runs"
  "old: hello"
  (generation-call (runtime-current runtime) 'agent-demo-response "hello"))

(runtime-eval!
 runtime
 "(define (agent-transform-user text) (string-upcase text))")

(test-equal "eval creates a new generation"
  2
  (generation-id (runtime-current runtime)))

(test-equal "new definition is live"
  "old: HELLO"
  (generation-call (runtime-current runtime) 'agent-demo-response "hello"))

(test-error "invalid authority policy is rejected"
  #t
  (runtime-eval! runtime "(define agent-shell-policy 'allow)"))

(test-equal "failed eval never activates"
  2
  (generation-id (runtime-current runtime)))

(test-error "live image cannot call ambient process APIs"
  #t
  (runtime-eval! runtime "(system* \"touch\" \"/tmp/should-not-exist\")"))

(test-equal "failed authority escape never activates"
  2
  (generation-id (runtime-current runtime)))

(runtime-rollback! runtime)

(test-equal "rollback restores the prior module"
  "old: hello"
  (generation-call (runtime-current runtime) 'agent-demo-response "hello"))

(test-assert "journal exists"
  (file-exists? (runtime-journal-path runtime)))

(test-end "live runtime")
