(define-module (live-agent main)
  #:use-module (ice-9 exceptions)
  #:use-module (ice-9 format)
  #:use-module (ice-9 readline)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-1)
  #:use-module (live-agent json)
  #:use-module (live-agent extensions)
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
    "  /extensions       list persistent extension artifacts and status\n"
    "  /extension-create NAME EXPR  create a disabled artifact\n"
    "  /extension-load NAME         enable an artifact as a generation\n"
    "  /extension-disable NAME      remove its exact active patch\n"
    "  /extension-export NAME       save all active patches as an artifact\n"
    "  /traces           show recent spans with generation and context choices\n"
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

(define (trace-preview value)
  (if (and (string? value) (> (string-length value) 100))
      (string-append (substring value 0 100) "…")
      value))

(define (trace-line-in-session? line session-id)
  (catch #t
    (lambda ()
      (let* ((span (json-read line))
             (attributes (json-object-ref span "attributes")))
        (string=? (json-object-ref attributes "session.id" "") session-id)))
    (lambda _ #f)))

(define (show-traces tracer)
  (format #t "trace file ~a~%session ~a~%" (tracer-path tracer)
          (tracer-session-id tracer))
  (let* ((session-id (tracer-session-id tracer))
         (session-lines
          (filter
           (lambda (line) (trace-line-in-session? line session-id))
           (trace-tail tracer 200)))
         (lines
          (if (> (length session-lines) 12)
              (take-right session-lines 12)
              session-lines)))
    (if (null? lines)
        (display "No completed spans yet.\n")
        (for-each
         (lambda (line)
           (catch #t
             (lambda ()
               (let* ((span (json-read line))
                      (attributes (json-object-ref span "attributes"))
                      (generation
                       (json-object-ref attributes "generation.id" "-"))
                      (paths
                       (json-object-ref attributes "context.paths" #f))
                      (output
                       (and (string=? (json-object-ref span "name") "agent.turn")
                            (json-object-ref attributes "output.value" #f))))
                 (format #t "~6,1f ms  gen=~a  ~a  ~a  ~a~a~a~%"
                         (json-object-ref span "duration_ms")
                         generation
                         (json-object-ref span "kind")
                         (json-object-ref span "name")
                         (json-object-ref span "status")
                         (if paths (format #f "  context=~a" paths) "")
                         (if output
                             (format #f "  result=~s" (trace-preview output))
                             ""))))
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

(define (extensions-directory)
  (string-append (getcwd) "/extensions"))

(define (extension-active? runtime name)
  (catch #t
    (lambda ()
      (if (member (extension-read (extensions-directory) name)
                  (generation-patches (runtime-current runtime)))
          #t
          #f))
    (lambda _ #f)))

(define (show-extensions runtime)
  (let ((names (extension-list (extensions-directory))))
    (if (null? names)
        (display "No extensions. Create one with /extension-create NAME EXPR.\n")
        (for-each
         (lambda (name)
           (format #t "~a  ~a~%"
                   (if (extension-active? runtime name) "enabled " "disabled")
                   name))
         names))))

(define (trimmed-command-argument line prefix)
  (string-trim-both (substring line (string-length prefix))))

(define (split-name-and-expression value)
  (let ((space (string-index value #\space)))
    (unless space
      (error "expected an extension name followed by a Scheme expression"))
    (let ((name (substring value 0 space))
          (expression (string-trim-both (substring value (+ space 1)))))
      (when (string-null? expression)
        (error "extension expression cannot be empty"))
      (list name expression))))

(define (create-extension! runtime name expression description)
  ;; Validate against the complete active image before persisting the artifact.
  (runtime-validate-patch! runtime expression)
  (extension-create! (extensions-directory) name expression description))

(define (load-extension! runtime name)
  (let ((expression (extension-read (extensions-directory) name)))
    (if (member expression (generation-patches (runtime-current runtime)))
        (runtime-current runtime)
        (runtime-apply-patch!
         runtime expression 'extension-load `((extension . ,name))))))

(define (disable-extension! runtime name)
  (let ((expression (extension-read (extensions-directory) name)))
    (runtime-remove-patch!
     runtime expression 'extension-disable `((extension . ,name)))))

(define (export-extension! runtime name description)
  (extension-export!
   (extensions-directory)
   name
   (generation-patches (runtime-current runtime))
   description))

(define (handle-command runtime tracer line)
  (cond
   ((string=? line "/help") (show-help) 'continue)
   ((string=? line "/show") (show-generation runtime) 'continue)
   ((string=? line "/generations") (show-generations runtime) 'continue)
   ((string=? line "/extensions") (show-extensions runtime) 'continue)
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
   ((string-prefix? "/extension-create " line)
    (when
        (try-transition
         "extension creation"
         (lambda ()
           (let* ((parts
                   (split-name-and-expression
                    (trimmed-command-argument line "/extension-create ")))
                  (path
                   (create-extension!
                    runtime (car parts) (cadr parts)
                    "Created explicitly from the interactive session.")))
             (format #t "Created disabled extension ~a.\n" path)
             #t)))
      (show-extensions runtime))
    'continue)
   ((or (string-prefix? "/extension-load " line)
        (string-prefix? "/extension-enable " line))
    (let* ((prefix (if (string-prefix? "/extension-load " line)
                       "/extension-load "
                       "/extension-enable "))
           (name (trimmed-command-argument line prefix)))
      (when (try-transition "extension load"
                            (lambda () (load-extension! runtime name)))
        (show-generation runtime)))
    'continue)
   ((string-prefix? "/extension-disable " line)
    (let ((name
           (trimmed-command-argument line "/extension-disable ")))
      (when (try-transition "extension disable"
                            (lambda () (disable-extension! runtime name)))
        (show-generation runtime)))
    'continue)
   ((string-prefix? "/extension-export " line)
    (let ((name
           (trimmed-command-argument line "/extension-export ")))
      (when
          (try-transition
           "extension export"
           (lambda ()
             (let ((path
                    (export-extension!
                     runtime name "Exported explicitly from the active generation.")))
               (format #t "Exported active patches to ~a.\n" path)
               #t)))
        (show-extensions runtime)))
    'continue)
   ((string=? line "/reset") 'reset)
   ((or (string=? line "/quit") (string=? line "/exit")) 'quit)
   (else
    (format (current-error-port) "Unknown command. Enter /help.~%")
    'continue)))

(define (tool-name value)
  (if (symbol? value) (symbol->string value) value))

(define live-change-intent-words
  '("fix" "change" "update" "modify" "edit" "remember" "configure"
    "switch" "enable" "disable" "always" "start" "stop"))

(define (explicit-live-change-request? text)
  (let ((lower (string-downcase text)))
    (any (lambda (word) (string-contains lower word))
         live-change-intent-words)))

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

(define (non-empty-tool-text arguments key)
  (let ((value (json-object-ref arguments key #f)))
    (unless (and (string? value) (not (string-null? (string-trim-both value))))
      (error "tool argument must be a non-empty string" key))
    value))

(define (last-item items)
  (if (null? (cdr items)) (car items) (last-item (cdr items))))

(define (assistant-explained-change? messages)
  (and (pair? messages)
       (let* ((message (last-item messages))
              (content (json-object-ref message "content" #f)))
         (and (string? content)
              (>= (string-length (string-trim-both content)) 12)))))

(define (execute-live-eval runtime generation arguments explained?)
  (catch #t
    (lambda ()
      (unless explained?
        (error
         "explain the exact live change and expected effect to the user before calling live_eval"))
      (let ((expression (non-empty-tool-text arguments "expression"))
            (summary (non-empty-tool-text arguments "summary"))
            (expected (non-empty-tool-text arguments "expected_behavior")))
        (let ((activated
               (runtime-apply-patch!
                runtime expression 'eval
                `((summary . ,summary) (expected-behavior . ,expected)))))
          (make-tool-result
           #t
           (format #f
                   "Live change applied: ~a\nBefore: generation ~a, fingerprint ~a\nAfter: generation ~a, fingerprint ~a\nExpected on the next user turn: ~a\nRequired follow-up: explain this before/after result to the user now. The current turn remains pinned to generation ~a; /rollback undoes it."
                   summary
                   (generation-id generation)
                   (generation-fingerprint generation)
                   (generation-id activated)
                   (generation-fingerprint activated)
                   expected
                   (generation-id generation))))))
    (lambda (key . arguments)
      (make-tool-result
       #f
       (format #f "live evaluation rejected (~a): ~s" key arguments)))))

(define (execute-extension runtime generation arguments)
  (catch #t
    (lambda ()
      (let ((action (non-empty-tool-text arguments "action")))
        (cond
         ((string=? action "list")
          (let ((names (extension-list (extensions-directory))))
            (make-tool-result
             #t
             (if (null? names)
                 "No extensions."
                 (string-join
                  (map (lambda (name)
                         (string-append
                          (if (extension-active? runtime name)
                              "enabled  " "disabled ")
                          name))
                       names)
                  "\n")))))
         ((string=? action "create")
          (let* ((name (non-empty-tool-text arguments "name"))
                 (expression (non-empty-tool-text arguments "expression"))
                 (description
                  (json-object-ref arguments "description"
                                   "Created by the agent from a live session."))
                 (path (create-extension! runtime name expression description)))
            (make-tool-result
             #t (format #f "Created disabled extension ~a." path))))
         ((string=? action "load")
          (let* ((name (non-empty-tool-text arguments "name"))
                 (before (runtime-current runtime))
                 (activated (load-extension! runtime name)))
            (make-tool-result
             #t
             (if (= (generation-id before) (generation-id activated))
                 (format #f "Extension ~a is already enabled in generation ~a."
                         name (generation-id before))
                 (format #f
                         "Enabled extension ~a: generation ~a (~a) -> generation ~a (~a). It applies on the next user turn."
                         name
                         (generation-id before) (generation-fingerprint before)
                         (generation-id activated)
                         (generation-fingerprint activated))))))
         ((string=? action "disable")
          (let* ((name (non-empty-tool-text arguments "name"))
                 (activated (disable-extension! runtime name)))
            (make-tool-result
             #t
             (format #f "Disabled extension ~a in generation ~a (~a)."
                     name (generation-id activated)
                     (generation-fingerprint activated)))))
         ((string=? action "export")
          (let* ((name (non-empty-tool-text arguments "name"))
                 (description
                  (json-object-ref arguments "description"
                                   "Exported by the agent from the active generation."))
                 (path (export-extension! runtime name description)))
            (make-tool-result
             #t (format #f "Exported active live patches to ~a." path))))
         (else (error "unknown extension action" action)))))
    (lambda (key . arguments)
      (make-tool-result
       #f
       (format #f "extension action rejected (~a): ~s" key arguments)))))

(define (valid-context-paths? paths)
  (and (list? paths)
       (<= (length paths) 8)
       (let loop ((remaining paths))
         (or (null? remaining)
             (and (string? (car remaining))
                  (not (string-null? (car remaining)))
                  (loop (cdr remaining)))))))

(define (join-context sections)
  (if (null? sections)
      ""
      (let loop ((remaining (cdr sections)) (result (car sections)))
        (if (null? remaining)
            result
            (loop (cdr remaining)
                  (string-append result "\n\n" (car remaining)))))))

(define (select-context-with-trace tracer parent generation line)
  (let ((span
         (trace-start!
          tracer "context.select" "RETRIEVER"
          `((generation.id . ,(generation-id generation))
            (input.value . ,line))
          parent)))
    (catch #t
      (lambda ()
        (let ((paths
               (generation-call generation 'agent-select-context line)))
          (unless (valid-context-paths? paths)
            (error
             "agent-select-context must return at most eight non-empty paths"
             paths))
          (let* ((sections
                  (map
                   (lambda (path)
                     (let ((result
                            (execute-tool
                             "read"
                             (json-object (cons "path" path))
                             (getcwd)
                             'deny
                             (lambda _ #f))))
                       (unless (tool-result-success? result)
                         (error "selected context could not be read"
                                path (tool-result-output result)))
                       (format #f "## ~a\n\n~a"
                               path (tool-result-output result))))
                   paths))
                 (content (join-context sections))
                 (encoded-paths (json-write (apply json-array paths))))
            (trace-end!
             span "OK"
             `((context.paths . ,encoded-paths)
               (output.value . ,content)))
            (list paths content))))
      (lambda (key . arguments)
        (trace-end!
         span "ERROR"
         `((error.type . ,(symbol->string key))
           (error.message . ,(format #f "~s" arguments))))
        (apply throw key arguments)))))

(define (execute-tool-calls runtime tracer parent generation provider calls
                            messages enabled-tools)
  (let loop ((remaining calls) (result messages))
    (if (null? remaining)
        result
        (let* ((call (car remaining))
               (name (tool-call-name call))
               (enabled? (if (member name enabled-tools) #t #f)))
          (runtime-record!
           runtime 'tool-call
           `((generation . ,(generation-id generation))
             (tool . ,name)
             (arguments . ,(json-write (tool-call-arguments call)))))
          (let* ((span
                  (trace-start!
                   tracer (string-append "tool." name) "TOOL"
                   `((generation.id . ,(generation-id generation))
                     (tool.name . ,name)
                     (input.value . ,(json-write (tool-call-arguments call))))
                   parent))
                 (outcome
                  (if (not enabled?)
                      (make-tool-result
                       #f
                       (format #f
                               "tool unavailable in this turn: ~a. It was not enabled by the active image or the user's explicit intent. Continue without it."
                               name))
                      (cond
                       ((string=? name "live_eval")
                        (execute-live-eval
                         runtime generation (tool-call-arguments call)
                         (assistant-explained-change? messages)))
                       ((string=? name "extension")
                        (execute-extension
                         runtime generation (tool-call-arguments call)))
                       (else
                        (execute-tool
                         name
                         (tool-call-arguments call)
                         (getcwd)
                         (generation-ref generation 'agent-shell-policy)
                         confirm-shell)))))
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

(define (complete-with-trace tracer parent generation-id provider model base-url
                             api-key messages enabled-tools stream? thinking round)
  (let ((span
         (trace-start!
          tracer (string-append (symbol->string provider) ".chat") "LLM"
          `((generation.id . ,generation-id)
            (llm.model_name . ,model)
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
         (configured-tools
          (map tool-name (generation-ref generation 'agent-tools)))
         ;; Self-mutation is absent from the provider request unless this user
         ;; turn contains explicit change intent. This prevents opportunistic
         ;; "helpful" rewrites when the user only asked a factual question.
         (enabled-tools
          (filter
           (lambda (name)
             (or (not (string=? name "live_eval"))
                 (explicit-live-change-request? line)))
           configured-tools))
         (max-rounds
          (generation-ref generation 'agent-max-tool-rounds))
         (stream? (generation-ref generation 'agent-stream?))
         (thinking (generation-ref generation 'agent-thinking))
         (system
          (make-message
           "system" (generation-ref generation 'agent-system-prompt)))
         (transformed-line
          (generation-call generation 'agent-transform-user line))
         (selected
          (select-context-with-trace
           tracer parent generation transformed-line))
         (context-paths (car selected))
         (context-text (cadr selected))
         (ephemeral-messages
          (append
           (list system)
           (if (null? context-paths)
               '()
               (list
                (make-message
                 "system"
                 (string-append
                  "Authoritative project context selected by agent-select-context "
                  "for this turn. Prefer it over earlier answers when they conflict.\n\n"
                  context-text))))))
         (ephemeral-count (length ephemeral-messages))
         (working
          (append
           ephemeral-messages
           history
           (list (make-message "user" transformed-line)))))
    (let loop ((messages working) (round 0))
      (let* ((outcome
              (complete-with-trace
               tracer parent (generation-id generation)
               provider model base-url api-key messages
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
              ;; Drop this turn's system prompt and selected context. The active
              ;; generation supplies both afresh for every user turn.
              (list (list-tail with-assistant ephemeral-count) reply))
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
