(define-module (live-agent main)
  #:use-module (ice-9 exceptions)
  #:use-module (ice-9 format)
  #:use-module (ice-9 readline)
  #:use-module (ice-9 textual-ports)
  #:use-module (live-agent json)
  #:use-module (live-agent generation)
  #:use-module (live-agent provider)
  #:use-module (live-agent runtime)
  #:use-module (live-agent trace)
  #:use-module (live-agent tools)
  #:export (main))

(define (usage)
  (display "Usage: lisp-agent [--agent PATH] [--state-dir PATH]\n"))

(define (parse-arguments args)
  (let loop ((rest args) (agent #f) (state-dir #f))
    (cond
     ((null? rest) (values agent state-dir))
     ((and (pair? (cdr rest)) (string=? (car rest) "--agent"))
      (loop (cddr rest) (cadr rest) state-dir))
     ((and (pair? (cdr rest)) (string=? (car rest) "--state-dir"))
      (loop (cddr rest) agent (cadr rest)))
     ((member (car rest) '("-h" "--help"))
      (usage)
      (exit 0))
     (else
      (format (current-error-port) "Unknown argument: ~a~%" (car rest))
      (usage)
      (exit 2)))))

(define (show-help)
  (display
   (string-append
    "Commands:\n"
    "  /show             inspect the active generation\n"
    "  /eval EXPR        transactionally add a live Scheme definition\n"
    "  /reload           reload the agent file and retain live patches\n"
    "  /reload-clean     reload the file without live patches\n"
    "  /rollback         restore the previous working generation\n"
    "  /generations      list the active and rollback generations\n"
    "  /traces           show recent local spans and their JSONL path\n"
    "  /reset            clear conversation state\n"
    "  /help             show this help\n"
    "  /quit             exit\n")))

(define (show-generation runtime)
  (let ((generation (runtime-current runtime)))
    (format #t
            "generation ~a  fingerprint ~a~%agent ~a  provider ~s  model ~a~%endpoint ~a  api-key-env ~s~%stream ~s  thinking ~s~%tools ~s  shell ~s  patches ~a~%source ~a~%"
            (generation-id generation)
            (generation-fingerprint generation)
            (generation-ref generation 'agent-name)
            (generation-ref generation 'agent-provider)
            (generation-ref generation 'agent-model)
            (generation-ref generation 'agent-base-url)
            (generation-ref generation 'agent-api-key-environment)
            (generation-ref generation 'agent-stream?)
            (generation-ref generation 'agent-thinking)
            (generation-ref generation 'agent-tools)
            (generation-ref generation 'agent-shell-policy)
            (length (generation-patches generation))
            (generation-source-path generation))))

(define (exception-detail exception)
  (catch #t
    (lambda ()
      (apply format
             (append (list #f (exception-message exception))
                     (exception-irritants exception))))
    (lambda _ (format #f "~s" exception))))

(define (show-generations runtime)
  (for-each
   (lambda (summary)
     (format #t "~a~a  ~a  patches=~a  loaded=~a~%"
             (if (= (cdr (assq 'id summary))
                    (generation-id (runtime-current runtime)))
                 "* "
                 "  ")
             (cdr (assq 'id summary))
             (cdr (assq 'fingerprint summary))
             (cdr (assq 'patches summary))
             (cdr (assq 'loaded-at summary))))
   (runtime-generation-summaries runtime)))

(define (show-traces tracer)
  (format #t "trace file ~a~%session ~a~%" (tracer-path tracer)
          (tracer-session-id tracer))
  (let ((lines (trace-tail tracer 12)))
    (if (null? lines)
        (display "No completed spans yet.\n")
        (for-each
         (lambda (line)
           (catch #t
             (lambda ()
               (let ((span (json-read line)))
                 (format #t "~6,1f ms  ~a  ~a  ~a~%"
                         (json-object-ref span "duration_ms")
                         (json-object-ref span "kind")
                         (json-object-ref span "name")
                         (json-object-ref span "status"))))
             (lambda _ (display line) (newline))))
         lines))))

(define (try-transition label thunk)
  (with-exception-handler
      (lambda (exception)
        (let ((detail (exception-detail exception)))
          (format (current-error-port)
                  "~a rejected; the active generation is unchanged: ~a~%"
                  label
                  detail))
        #f)
    thunk
    #:unwind? #t))

(define (handle-command runtime tracer line)
  (cond
   ((string=? line "/help") (show-help) 'continue)
   ((string=? line "/show") (show-generation runtime) 'continue)
   ((string=? line "/generations") (show-generations runtime) 'continue)
   ((string=? line "/traces") (show-traces tracer) 'continue)
   ((string=? line "/reload")
    (when (try-transition "reload" (lambda () (runtime-reload! runtime #t)))
      (show-generation runtime))
    'continue)
   ((string=? line "/reload-clean")
    (when (try-transition "clean reload" (lambda () (runtime-reload! runtime #f)))
      (show-generation runtime))
    'continue)
   ((string=? line "/rollback")
    (let ((generation (runtime-rollback! runtime)))
      (if generation
          (show-generation runtime)
          (display "No previous generation is available.\n")))
    'continue)
   ((string-prefix? "/eval " line)
    (let ((expression (substring line 6)))
      (when (try-transition "evaluation"
                            (lambda () (runtime-eval! runtime expression)))
        (show-generation runtime)))
    'continue)
   ((string=? line "/reset") 'reset)
   ((or (string=? line "/quit") (string=? line "/exit")) 'quit)
   (else
    (format (current-error-port) "Unknown command. Enter /help.~%")
    'continue)))

(define (tool-name value)
  (if (symbol? value) (symbol->string value) value))

(define (read-user-line prompt)
  (if (isatty? (current-input-port))
      (readline prompt)
      (get-line (current-input-port))))

(define (confirm-shell command)
  (format #t "\nShell requests:\n  ~a~%" command)
  (force-output)
  (let ((answer (read-user-line "Approve this command? [y/N] ")))
    (and (string? answer)
         (member (string-downcase (string-trim-both answer)) '("y" "yes")))))

(define (record-input! runtime generation turn-count line)
  (runtime-record!
   runtime 'user-input
   `((generation . ,(generation-id generation))
     (turn . ,turn-count)
     (text . ,line))))

(define (record-output! runtime generation turn-count reply)
  (runtime-record!
   runtime 'assistant-output
   `((generation . ,(generation-id generation))
     (turn . ,turn-count)
     (text . ,reply))))

(define (demo-turn! runtime generation history line turn-count)
  (let ((reply (generation-call generation 'agent-demo-response line)))
    (record-output! runtime generation turn-count reply)
    (display reply)
    (newline)
    (list
     (append history
             (list (make-message "user" line)
                   (make-message "assistant" reply)))
     reply)))

(define (execute-live-eval runtime generation arguments)
  (let ((expression (json-object-ref arguments "expression"))
        (reason (json-object-ref arguments "reason" "requested live change")))
    (catch #t
      (lambda ()
        (let ((activated (runtime-eval! runtime expression)))
          (make-tool-result
           #t
           (format #f
                   "Activated generation ~a (~a) for the next user turn. Current turn remains pinned to generation ~a; /rollback undoes it."
                   (generation-id activated)
                   reason
                   (generation-id generation)))))
      (lambda (key . arguments)
        (make-tool-result
         #f
         (format #f "live evaluation rejected (~a): ~s" key arguments))))))

(define (execute-tool-calls runtime tracer parent generation provider calls
                            messages enabled-tools)
  (let loop ((remaining calls) (result messages))
    (if (null? remaining)
        result
        (let* ((call (car remaining))
               (name (tool-call-name call)))
          (unless (member name enabled-tools)
            (error "model requested a tool outside the live image" name))
          (runtime-record!
           runtime 'tool-call
           `((generation . ,(generation-id generation))
             (tool . ,name)
             (arguments . ,(json-write (tool-call-arguments call)))))
          (let* ((span
                  (trace-start!
                   tracer (string-append "tool." name) "TOOL"
                   `((tool.name . ,name)
                     (input.value . ,(json-write (tool-call-arguments call))))
                   parent))
                 (outcome
                  (if (string=? name "live_eval")
                      (execute-live-eval
                       runtime generation (tool-call-arguments call))
                      (execute-tool
                       name
                       (tool-call-arguments call)
                       (getcwd)
                       (generation-ref generation 'agent-shell-policy)
                       confirm-shell)))
                 (ok? (tool-result-success? outcome))
                 (output (tool-result-output outcome)))
            (trace-end! span (if ok? "OK" "ERROR")
                        `((output.value . ,output)))
            (runtime-record!
             runtime 'tool-result
             `((generation . ,(generation-id generation))
               (tool . ,name)
               (output . ,output)))
            (loop (cdr remaining)
                  (append result
                          (list
                           (make-tool-result-message
                            provider
                            (tool-call-id call)
                            name
                            output)))))))))

(define (usage-attributes completion)
  (let* ((root (completion-usage completion))
         (openai-usage
          (and (json-object? root)
               (json-object-ref root "usage" #f)))
         (prompt
          (if (and openai-usage (json-object? openai-usage))
              (json-object-ref openai-usage "prompt_tokens" #f)
              (and (json-object? root)
                   (json-object-ref root "prompt_eval_count" #f))))
         (output
          (if (and openai-usage (json-object? openai-usage))
              (json-object-ref openai-usage "completion_tokens" #f)
              (and (json-object? root)
                   (json-object-ref root "eval_count" #f)))))
    (append
     (if prompt `((llm.token_count.prompt . ,prompt)) '())
     (if output `((llm.token_count.completion . ,output)) '()))))

(define (complete-with-trace tracer parent provider model base-url api-key
                             messages enabled-tools stream? thinking round)
  (let ((span
         (trace-start!
          tracer (string-append (symbol->string provider) ".chat") "LLM"
          `((llm.model_name . ,model)
            (llm.provider . ,(symbol->string provider))
            (llm.round . ,round)
            (input.value . ,(json-write (apply json-array messages))))
          parent))
        (thinking-started? #f)
        (content-started? #f))
    (define (on-thinking chunk)
      (unless thinking-started?
        (set! thinking-started? #t)
        (display "thinking> "))
      (display chunk)
      (force-output))
    (define (on-content chunk)
      (unless content-started?
        (set! content-started? #t)
        (when thinking-started? (newline))
        (display "assistant> "))
      (display chunk)
      (force-output))
    (catch #t
      (lambda ()
        (let ((completion
               (provider-complete
                provider model base-url api-key messages enabled-tools
                stream? thinking on-content on-thinking)))
          (when (or thinking-started? content-started?)
            (newline)
            (force-output))
          (trace-end!
           span "OK"
           (append
            `((output.value . ,(or (completion-content completion) ""))
              (llm.thinking . ,(or (completion-thinking completion) "")))
            (usage-attributes completion)))
          (cons completion content-started?)))
      (lambda (key . arguments)
        (when (or thinking-started? content-started?)
          (newline)
          (force-output))
        (trace-end! span "ERROR"
                    `((error.type . ,(symbol->string key))
                      (error.message . ,(format #f "~s" arguments))))
        (apply throw key arguments)))))

(define (provider-turn! runtime tracer parent generation history line turn-count)
  (let* ((provider (generation-ref generation 'agent-provider))
         (model (generation-ref generation 'agent-model))
         (base-url (generation-ref generation 'agent-base-url))
         (key-environment
          (generation-ref generation 'agent-api-key-environment))
         (api-key (and key-environment (getenv key-environment)))
         (enabled-tools
          (map tool-name (generation-ref generation 'agent-tools)))
         (max-rounds
          (generation-ref generation 'agent-max-tool-rounds))
         (stream? (generation-ref generation 'agent-stream?))
         (thinking (generation-ref generation 'agent-thinking))
         (system
          (make-message
           "system" (generation-ref generation 'agent-system-prompt)))
         (transformed-line
          (generation-call generation 'agent-transform-user line))
         (working
          (append
           (list system)
           history
           (list (make-message "user" transformed-line)))))
    (let loop ((messages working) (round 0))
      (let* ((outcome
              (complete-with-trace
               tracer parent provider model base-url api-key messages
               enabled-tools stream? thinking round))
             (completion (car outcome))
             (content-streamed? (cdr outcome))
             (calls (completion-tool-calls completion))
             (with-assistant
              (append messages (list (completion-assistant-message completion)))))
        (if (null? calls)
            (let ((reply (or (completion-content completion) "")))
              (record-output! runtime generation turn-count reply)
              (unless content-streamed?
                (unless (string-null? (or (completion-thinking completion) ""))
                  (format #t "thinking> ~a~%" (completion-thinking completion)))
                (format #t "assistant> ~a~%" reply))
              ;; Drop the current system message. The active generation supplies
              ;; a fresh one at the start of every user turn.
              (list (cdr with-assistant) reply))
            (begin
              (when (>= round max-rounds)
                (error "tool round limit reached" max-rounds))
              (loop
               (execute-tool-calls
                runtime tracer parent generation provider calls with-assistant
                enabled-tools)
               (+ round 1))))))))

(define (perform-turn! runtime tracer history line turn-count)
  (let* ((generation (runtime-current runtime))
         (span
          (trace-start!
           tracer "agent.turn" "AGENT"
           `((generation.id . ,(generation-id generation))
             (turn.number . ,turn-count)
             (input.value . ,line)))))
    (record-input! runtime generation turn-count line)
    (with-exception-handler
        (lambda (exception)
          (trace-end! span "ERROR"
                      `((error.message . ,(exception-detail exception))))
          (format (current-error-port) "turn failed: ~a~%"
                  (exception-detail exception))
          #f)
      (lambda ()
        (let ((new-history
               (if (string=? (generation-ref generation 'agent-model) "demo")
                   (demo-turn! runtime generation history line turn-count)
                   (provider-turn!
                    runtime tracer span generation history line turn-count))))
          (trace-end! span "OK" `((output.value . ,(cadr new-history))))
          (list 'ok (car new-history))))
      #:unwind? #t)))

(define (repl runtime tracer)
  (show-generation runtime)
  (display "Enter text to exercise the live image, or /help.\n")
  (force-output)
  (let loop ((turn-count 1) (history '()))
    (let ((line (read-user-line "live-agent> ")))
      (cond
       ((eof-object? line) (newline))
       ((string-null? (string-trim-both line)) (loop turn-count history))
       ((string-prefix? "/" line)
        (case (handle-command runtime tracer line)
          ((quit) #t)
          ((reset)
           (display "Conversation state cleared.\n")
           (loop 1 '()))
          (else (loop turn-count history))))
       (else
        (let ((result (perform-turn! runtime tracer history line turn-count)))
          (if result
              (loop (+ turn-count 1) (cadr result))
              (loop turn-count history))))))))

(define (main args)
  (call-with-values
      (lambda () (parse-arguments args))
    (lambda (agent-path state-directory)
      (unless (and agent-path state-directory)
        (usage)
        (exit 2))
      (let* ((runtime
             (try-transition
              "startup"
              (lambda () (make-runtime agent-path state-directory))))
             (tracer (and runtime (make-tracer state-directory))))
        (unless runtime (exit 1))
        (dynamic-wind
          (lambda () #t)
          (lambda () (repl runtime tracer))
          (lambda () (trace-close! tracer)))))))

(main (cdr (command-line)))
