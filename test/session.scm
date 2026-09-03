(use-modules (srfi srfi-64)
             (live-agent generation)
             (live-agent json)
             (live-agent provider)
             (live-agent runtime)
             (live-agent session))

(define fixture-source
  (string-append
   "(define agent-name \"session-fixture\")\n"
   "(define agent-provider 'ollama)\n"
   "(define agent-model \"demo\")\n"
   "(define agent-base-url \"http://127.0.0.1:9999\")\n"
   "(define agent-api-key-environment #f)\n"
   "(define agent-stream? #t)\n"
   "(define agent-thinking #f)\n"
   "(define agent-max-tool-rounds 2)\n"
   "(define agent-system-prompt \"fixture prompt\")\n"
   "(define agent-tools '(read))\n"
   "(define agent-shell-policy 'deny)\n"
   "(define (agent-select-context text) '())\n"
   "(define (agent-transform-user text) text)\n"
   "(define (agent-demo-response text) (string-append \"session: \" text))\n"))

(define test-root
  (string-append "/tmp/lisp-agent-session-test-" (number->string (getpid))))
(define source-path (string-append test-root "/agent.scm"))

(system* "mkdir" "-p" test-root)
(call-with-output-file source-path
  (lambda (port) (display fixture-source port)))

(test-begin "durable session")

(define state (open-session! test-root "dogfood" 'new))
(define runtime
  (make-runtime source-path (session-directory state)
                (session-patches state) (session-generation-id state)))
(define history
  (list (make-message "user" "hello")
        (make-message "assistant" "hi")))

(runtime-eval! runtime "(set! agent-system-prompt \"remembered\")")
(save-session! state runtime history 2)
(close-session! state)

(define resumed (open-session! test-root "dogfood" 'resume))

(test-assert "resume is distinguished from a new session"
  (session-resumed? resumed))
(test-equal "session identity survives restart"
  (session-id state)
  (session-id resumed))
(test-equal "conversation history survives restart"
  "hi"
  (json-object-ref (cadr (session-history resumed)) "content"))
(test-equal "turn number survives restart" 2 (session-next-turn resumed))
(test-equal "generation number survives restart" 2 (session-generation-id resumed))
(test-equal "live patches survive restart"
  '("(set! agent-system-prompt \"remembered\")")
  (session-patches resumed))

(define restored-runtime
  (make-runtime source-path (session-directory resumed)
                (session-patches resumed) (session-generation-id resumed)
                (session-fingerprint resumed)))

(test-equal "restored patch is rebuilt into the live image"
  "remembered"
  (generation-ref (runtime-current restored-runtime) 'agent-system-prompt))
(test-equal "named session is discoverable"
  '("dogfood")
  (list-session-names test-root))
(test-error "one durable session cannot have two live owners"
  #t
  (open-session! test-root "dogfood" 'resume))

(call-with-output-file source-path
  (lambda (port)
    (display
     (string-append fixture-source "\n(define extension-source-version 2)\n")
     port)))
(define source-changed-runtime
  (make-runtime source-path (session-directory resumed)
                (session-patches resumed) (session-generation-id resumed)
                (session-fingerprint resumed)))
(test-equal "source changes while stopped advance the generation"
  3
  (generation-id (runtime-current source-changed-runtime)))
(test-error "new refuses to overwrite an existing session"
  #t
  (open-session! test-root "dogfood" 'new))
(test-error "resume requires an existing checkpoint"
  #t
  (open-session! test-root "missing" 'resume))
(test-error "session names cannot traverse directories"
  #t
  (open-session! test-root "../escape" 'auto))

(close-session! resumed)

(test-end "durable session")
