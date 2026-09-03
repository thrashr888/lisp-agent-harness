(use-modules (ice-9 textual-ports)
             (srfi srfi-64)
             (live-agent generation)
             (live-agent runtime))

(define fixture-source
  (string-append
   "(define agent-name \"fixture\")\n"
   "(define agent-provider 'ollama)\n"
   "(define agent-model \"demo\")\n"
   "(define agent-base-url \"http://127.0.0.1:9999\")\n"
   "(define agent-api-key-environment \"OPENAI_API_KEY\")\n"
   "(define agent-stream? #t)\n"
   "(define agent-thinking 'low)\n"
   "(define agent-max-tool-rounds 2)\n"
   "(define agent-system-prompt \"fixture prompt\")\n"
   "(define agent-tools '(read))\n"
   "(define agent-shell-policy 'deny)\n"
   "(define (agent-select-context text) '(\"README.md\"))\n"
   "(define (agent-transform-user text) text)\n"
   "(define (agent-demo-response text) (string-append \"old: \" (agent-transform-user text)))\n"))

(define test-root
  (string-append "/tmp/lisp-agent-harness-test-" (number->string (getpid))))
(define source-path (string-append test-root "/agent.scm"))
(define state-path (string-append test-root "/state"))

(define (replace-once text old new)
  (let ((index (string-contains text old)))
    (unless index (error "test fixture text not found" old))
    (string-append
     (substring text 0 index)
     new
     (substring text (+ index (string-length old))))))

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

(runtime-eval!
 runtime
 "(define (agent-select-context text) '(\"LICENSE\"))")

(test-equal "context selection is live"
  '("LICENSE")
  (generation-call (runtime-current runtime) 'agent-select-context "license"))

(test-error "latent selector errors are rejected before activation"
  #t
  (runtime-eval!
   runtime
   "(define (agent-select-context text) (missing-predicate text))"))

(test-equal "failed selector never activates"
  3
  (generation-id (runtime-current runtime)))

(runtime-eval!
 runtime
 "(define (agent-select-context text) (cond ((string-contains? text \"license\") '(\"LICENSE\")) (else '())))")

(test-equal "common selector vocabulary is available to live code"
  '("LICENSE")
  (generation-call (runtime-current runtime) 'agent-select-context "read license"))

(test-error "invalid authority policy is rejected"
  #t
  (runtime-eval! runtime "(define agent-shell-policy 'allow)"))

(test-equal "failed eval never activates"
  4
  (generation-id (runtime-current runtime)))

(test-error "live image cannot call ambient process APIs"
  #t
  (runtime-eval! runtime "(system* \"touch\" \"/tmp/should-not-exist\")"))

(test-equal "failed authority escape never activates"
  4
  (generation-id (runtime-current runtime)))

(test-error "live patches cannot replace language primitives"
  #t
  (runtime-eval! runtime "(define string-append (lambda values \"oops\"))"))

(test-error "live patches cannot run arbitrary top-level expressions"
  #t
  (runtime-eval! runtime "(+ 1 2)"))

(runtime-eval!
 runtime
 "(begin (define extension-label \"safe\") (set! agent-system-prompt \"updated\"))")

(test-equal "begin may group namespaced live changes"
  "safe"
  (generation-ref (runtime-current runtime) 'extension-label))

(runtime-rollback! runtime)

(runtime-rollback! runtime)

(test-equal "rollback restores the prior module"
  "old: HELLO"
  (generation-call (runtime-current runtime) 'agent-demo-response "hello"))

(test-assert "journal exists"
  (file-exists? (runtime-journal-path runtime)))

(call-with-output-file source-path
  (lambda (port)
    (display
     (replace-once fixture-source "old: " "source: ")
     port)))

(define reloaded (runtime-reload-if-changed! runtime))

(test-equal "changed source activates a fresh generation"
  6
  (generation-id reloaded))

(test-equal "source reload retains active live patches"
  "source: HELLO"
  (generation-call (runtime-current runtime) 'agent-demo-response "hello"))

(test-eq "unchanged source does not create a generation"
  #f
  (runtime-reload-if-changed! runtime))

(call-with-output-file source-path
  (lambda (port) (display "(define agent-name \"incomplete\")\n" port)))

(test-error "invalid changed source is rejected"
  #t
  (runtime-reload-if-changed! runtime))

(test-equal "invalid source leaves the working generation active"
  "source: HELLO"
  (generation-call (runtime-current runtime) 'agent-demo-response "hello"))

(test-end "live runtime")
