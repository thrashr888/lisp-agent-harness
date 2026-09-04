(define-module (live-agent main)
  #:use-module (ice-9 exceptions)
  #:use-module (ice-9 format)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 readline)
  #:use-module (ice-9 threads)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-1)
  #:use-module (live-agent compaction)
  #:use-module (live-agent json)
  #:use-module (live-agent extensions)
  #:use-module (live-agent generation)
  #:use-module (live-agent provider)
  #:use-module (live-agent prompt)
  #:use-module (live-agent recovery)
  #:use-module (live-agent runtime)
  #:use-module (live-agent session)
  #:use-module (live-agent trace)
  #:use-module (live-agent tools)
  #:export (main))

(define turn-active? #f)

(define (cancelled? key)
  (eq? key 'turn-cancelled))

(define (install-cancellation-handler!)
  (sigaction
   SIGINT
   (lambda _
     (when turn-active? (throw 'turn-cancelled "cancelled by user")))))

(define (usage)
  (display
   (string-append
    "Usage: shift [--agent PATH] [--state-dir PATH] [--watch|--no-watch]\n"
    "                  [--session NAME|--new-session NAME|--resume NAME] [PROMPT]\n"
    "       shift --list-sessions [--state-dir PATH]\n")))

(define (parse-arguments args)
  (let loop ((rest args) (agent #f) (state-dir #f) (watch? #t)
             (session-name #f) (session-mode #f) (list? #f)
             (initial-prompt #f))
    (cond
     ((null? rest)
      (values agent state-dir watch? session-name session-mode list?
              initial-prompt))
     ((and (pair? (cdr rest)) (string=? (car rest) "--agent"))
      (loop (cddr rest) (cadr rest) state-dir watch?
            session-name session-mode list? initial-prompt))
     ((and (pair? (cdr rest)) (string=? (car rest) "--state-dir"))
      (loop (cddr rest) agent (cadr rest) watch?
            session-name session-mode list? initial-prompt))
     ((string=? (car rest) "--watch")
      (loop (cdr rest) agent state-dir #t session-name session-mode list?
            initial-prompt))
     ((string=? (car rest) "--no-watch")
      (loop (cdr rest) agent state-dir #f session-name session-mode list?
            initial-prompt))
     ((and (pair? (cdr rest))
           (member (car rest) '("--session" "--new-session" "--resume")))
      (when session-name
        (format (current-error-port) "Only one session selector may be used.\n")
        (exit 2))
      (loop
       (cddr rest) agent state-dir watch? (cadr rest)
       (cond
        ((string=? (car rest) "--new-session") 'new)
        ((string=? (car rest) "--resume") 'resume)
        (else 'auto))
       list? initial-prompt))
     ((string=? (car rest) "--list-sessions")
      (loop (cdr rest) agent state-dir watch?
            session-name session-mode #t initial-prompt))
     ((member (car rest) '("-h" "--help"))
      (usage)
      (exit 0))
     ((not (string-prefix? "-" (car rest)))
      (when initial-prompt
        (format (current-error-port)
                "Only one positional startup prompt may be provided; quote prompts containing spaces.\n")
        (exit 2))
      (loop (cdr rest) agent state-dir watch?
            session-name session-mode list? (car rest)))
     (else
      (format (current-error-port) "Unknown argument: ~a~%" (car rest))
      (usage)
      (exit 2)))))

(define (show-help)
  (display
   (string-append
    "Commands:\n"
    "  /show             inspect the active generation\n"
    "  /thinking [MODE]  show or set off/on/low/medium/high\n"
    "  /stream [on|off]  show or set streaming output\n"
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
    "  /traces [QUERY]   list recent spans or search all session traces\n"
    "  /trace SPAN_ID    inspect one full span returned by trace search\n"
    "  /compact          summarize older history and retain recent turns\n"
    "  /recover          inspect an interrupted tool record\n"
    "  /recover retry    explicitly retry the recorded tool call\n"
    "  /recover discard  discard the recorded tool call\n"
    "  /session          show the durable session identity and checkpoint\n"
    "  /reset            clear conversation state\n"
    "  /help             show this help\n"
    "  /quit             exit\n")))

(define (show-generation runtime)
  (let ((generation (runtime-current runtime)))
    (format #t
            "generation ~a  fingerprint ~a~%agent ~a  provider ~s  model ~a~%endpoint ~a  api-key-env ~s~%stream ~s  thinking ~s  keep-alive ~s~%tools ~s  shell ~s  patches ~a~%compaction threshold ~a  keep recent ~a~%source ~a~%"
            (generation-id generation)
            (generation-fingerprint generation)
            (generation-ref generation 'agent-name)
            (generation-ref generation 'agent-provider)
            (generation-ref generation 'agent-model)
            (generation-ref generation 'agent-base-url)
            (generation-ref generation 'agent-api-key-environment)
            (generation-ref generation 'agent-stream?)
            (generation-ref generation 'agent-thinking)
            (generation-ref generation 'agent-keep-alive)
            (generation-ref generation 'agent-tools)
            (generation-ref generation 'agent-shell-policy)
            (length (generation-patches generation))
            (generation-ref generation 'agent-compaction-threshold)
            (generation-ref generation 'agent-compaction-keep-recent)
            (generation-source-path generation))))

(define (short-fingerprint value)
  (substring value 0 (min 12 (string-length value))))

(define (enabled-label value)
  (if value "on" "off"))

(define (show-banner runtime watch? session)
  (let ((generation (runtime-current runtime)))
    (format #t
            "~%shift λ~%  ~a · generation ~a · ~a~%  ~a via ~a~%  stream ~a · thinking ~a · watch ~a~%  ~a tools · shell ~a · /help for commands~%~%"
            (generation-ref generation 'agent-name)
            (generation-id generation)
            (short-fingerprint (generation-fingerprint generation))
            (generation-ref generation 'agent-model)
            (generation-ref generation 'agent-provider)
            (enabled-label (generation-ref generation 'agent-stream?))
            (let ((thinking (generation-ref generation 'agent-thinking)))
              (if (boolean? thinking) (enabled-label thinking) thinking))
            (enabled-label watch?)
            (length (generation-ref generation 'agent-tools))
            (generation-ref generation 'agent-shell-policy))
    (when session
      (format #t "  session ~a · ~a · turn ~a~%"
              (session-name session)
              (if (session-resumed? session) "resumed" "new")
              (session-next-turn session)))))

(define (exception-detail exception)
  (catch #t
    (lambda ()
      (apply format
             (append (list #f (exception-message exception))
                     (exception-irritants exception))))
    (lambda _ (format #f "~s" exception))))

(define* (start-agent-watcher! runtime #:optional (on-reloaded (lambda () #t)))
  (let ((stopped? #f)
        (last-attempt #f))
    (define (notice-reloaded generation)
      (format #t "~%\u21bb agent image reloaded · generation ~a · ~a~%"
              (generation-id generation)
              (short-fingerprint (generation-fingerprint generation)))
      (force-output))
    (define (notice-rejected detail)
      (runtime-record!
       runtime 'generation-reload-rejected
       `((generation . ,(generation-id (runtime-current runtime)))
         (error . ,detail)))
      (format (current-error-port)
              "~%\u21bb agent image change rejected · generation ~a remains active~%  ~a~%"
              (generation-id (runtime-current runtime))
              detail)
      (force-output (current-error-port)))
    (define (check-once!)
      (catch #t
        (lambda ()
          (let* ((current (runtime-current runtime))
                 (source-path (generation-source-path current))
                 (source-text (read-source-file source-path)))
            (cond
             ((string=? source-text (generation-source-text current))
              (set! last-attempt #f))
             ((and last-attempt (string=? source-text last-attempt)) #f)
             (else
              ;; Remember rejected content too, so an editor's incomplete save
              ;; does not cause a retry storm. A later distinct save retries.
              (set! last-attempt source-text)
              (catch #t
                (lambda ()
                  (let ((generation (runtime-reload-if-changed! runtime)))
                    (when generation
                      (on-reloaded)
                      (notice-reloaded generation))))
                (lambda (key . arguments)
                  (notice-rejected (format #f "~s: ~s" key arguments))))))))
        ;; Atomic editor renames can briefly make the source unreadable. Treat
        ;; that as a wake-up miss and retry, not as a rejected generation.
        (lambda _ #f)))
    (let ((thread
           (call-with-new-thread
            (lambda ()
              (let loop ()
                (unless stopped?
                  (usleep 250000)
                  (unless stopped?
                    (check-once!)
                    (loop))))))))
      (lambda ()
        (set! stopped? #t)
        (join-thread thread)))))

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

(define* (show-traces tracer #:optional (query #f) (span-id #f))
  (format #t "trace file ~a~%session ~a~%" (tracer-path tracer)
          (tracer-session-id tracer))
  (call-with-values
      (lambda ()
        (trace-search tracer #:query query #:span-id span-id
                      #:limit (if span-id 1 12)))
    (lambda (spans matched scanned malformed)
      (when query
        (format #t "query ~s · ~a matches across ~a spans~%"
                query matched scanned))
      (when (> malformed 0)
        (format #t "ignored ~a malformed trace lines~%" malformed))
      (if (null? spans)
          (display "No matching completed spans.\n")
          (for-each
           (lambda (span)
             (if span-id
                 (begin (display (json-write span)) (newline))
                 (format #t "~6,1f ms  gen=~a turn=~a  ~a  ~a  ~a  span=~a~a~%"
                         (json-object-ref span "duration_ms")
                         (json-object-ref span "generation" "-")
                         (json-object-ref span "turn" "-")
                         (json-object-ref span "kind")
                         (json-object-ref span "name")
                         (json-object-ref span "status")
                         (json-object-ref span "span_id")
                         (let ((preview (json-object-ref span "preview" "")))
                           (if (and (string? preview)
                                    (not (string-null? preview)))
                               (format #f "  ~s" preview)
                               "")))))
           spans)))))

(define (execute-traces tracer arguments)
  (catch #t
    (lambda ()
      (let* ((limit (json-object-ref arguments "limit" 12))
             (errors-only? (json-object-ref arguments "errors_only" #f))
             (query (json-object-ref arguments "query" #f))
             (span-id (json-object-ref arguments "span_id" #f))
             (name (json-object-ref arguments "name" #f))
             (kind (json-object-ref arguments "kind" #f))
             (status (json-object-ref arguments "status" #f))
             (generation (json-object-ref arguments "generation" #f))
             (turn (json-object-ref arguments "turn" #f)))
        (unless (and (integer? limit) (>= limit 1) (<= limit 50))
          (error "trace limit must be an integer from 1 through 50" limit))
        (unless (boolean? errors-only?)
          (error "errors_only must be a boolean" errors-only?))
        (for-each
         (lambda (entry)
           (let ((value (cdr entry)))
             (unless (or (not value)
                         (and (string? value)
                              (not (string-null? (string-trim-both value)))))
               (error "trace text filters must be non-empty strings" entry))
             (when (and (string? value) (> (string-length value) 256))
               (error "trace text filters are limited to 256 characters" (car entry)))))
         `((query . ,query) (span_id . ,span-id) (name . ,name)
           (kind . ,kind) (status . ,status)))
        (unless (or (not generation) (and (integer? generation) (> generation 0)))
          (error "generation must be a positive integer" generation))
        (unless (or (not turn) (and (integer? turn) (> turn 0)))
          (error "turn must be a positive integer" turn))
        (call-with-values
            (lambda ()
              (trace-search
               tracer #:query query #:span-id span-id #:name name #:kind kind
               #:status status #:generation generation #:turn turn
               #:errors-only? errors-only? #:limit (if span-id 1 limit)))
          (lambda (found matched scanned malformed)
            (let loop ((spans found) (truncated? #f))
              (let*
                  ((response
                    (json-object
                     (cons "session_id" (tracer-session-id tracer))
                     (cons "trace_file" (tracer-path tracer))
                     (cons "mode"
                           (if span-id "get" (if query "search" "list")))
                     (cons "query" (or query json-null))
                     (cons "matched" matched)
                     (cons "scanned" scanned)
                     (cons "malformed" malformed)
                     (cons "truncated" truncated?)
                     (cons "spans" (apply json-array spans))))
                   (encoded (json-write response)))
                (if (or (<= (string-length encoded) (* 64 1024))
                        (null? spans))
                    (make-tool-result #t encoded)
                    (loop (drop-right spans 1) #t))))))))
    (lambda (key . arguments)
      (make-tool-result
       #f (format #f "trace inspection failed (~a): ~s" key arguments)))))

(define (runtime-state-directory tracer)
  (dirname (tracer-path tracer)))

(define (show-recovery tracer)
  (let ((pending (recovery-read (runtime-state-directory tracer))))
    (if pending
        (format #t
                "Interrupted tool may have partially executed.\n  tool ~a\n  generation ~a\n  started ~a\n  arguments ~a\nUse /recover retry only if repeating it is safe, or /recover discard.\n"
                (json-object-ref pending "tool")
                (json-object-ref pending "generation_id")
                (json-object-ref pending "created_at")
                (json-write (json-object-ref pending "arguments")))
        (display "No interrupted tool call is pending.\n"))))

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

(define (set-live-setting! runtime label binding source-value display-value)
  (when
      (try-transition
       label
       (lambda ()
         (runtime-eval!
          runtime
          (format #f "(set! ~a ~a)" binding source-value))))
    (format #t "~a ~a · generation ~a~%"
            label display-value
            (generation-id (runtime-current runtime)))))

(define (handle-thinking-command runtime line)
  (let* ((generation (runtime-current runtime))
         (current (generation-ref generation 'agent-thinking))
         (value
          (if (string=? line "/thinking")
              ""
              (trimmed-command-argument line "/thinking "))))
    (cond
     ((string-null? value)
      (format #t "thinking ~a~%"
              (if (boolean? current) (enabled-label current) current)))
     ((string=? value "off")
      (set-live-setting! runtime "thinking" 'agent-thinking "#f" "off"))
     ((string=? value "on")
      (set-live-setting! runtime "thinking" 'agent-thinking "#t" "on"))
     ((member value '("low" "medium" "high"))
      (set-live-setting!
       runtime "thinking" 'agent-thinking
       (string-append "'" value) value))
     (else
      (format (current-error-port)
              "thinking mode must be off, on, low, medium, or high~%")))))

(define (handle-stream-command runtime line)
  (let* ((generation (runtime-current runtime))
         (current (generation-ref generation 'agent-stream?))
         (value
          (if (string=? line "/stream")
              ""
              (trimmed-command-argument line "/stream "))))
    (cond
     ((string-null? value) (format #t "stream ~a~%" (enabled-label current)))
     ((string=? value "off")
      (set-live-setting! runtime "stream" 'agent-stream? "#f" "off"))
     ((string=? value "on")
      (set-live-setting! runtime "stream" 'agent-stream? "#t" "on"))
     (else
      (format (current-error-port) "stream mode must be off or on~%")))))

(define (show-session session)
  (if session
      (format #t "session ~a~%id ~a~%checkpoint ~a/session.json~%"
              (session-name session)
              (session-id session)
              (session-directory session))
      (display "This is an ephemeral session. Start with --session NAME to persist it.\n")))

(define (handle-command runtime tracer session line)
  (cond
   ((string=? line "/help") (show-help) 'continue)
   ((string=? line "/show") (show-generation runtime) 'continue)
   ((or (string=? line "/thinking") (string-prefix? "/thinking " line))
    (handle-thinking-command runtime line)
    'continue)
   ((or (string=? line "/stream") (string-prefix? "/stream " line))
    (handle-stream-command runtime line)
    'continue)
   ((string=? line "/generations") (show-generations runtime) 'continue)
   ((string=? line "/extensions") (show-extensions runtime) 'continue)
   ((string=? line "/traces") (show-traces tracer) 'continue)
   ((string-prefix? "/traces " line)
    (show-traces tracer (trimmed-command-argument line "/traces "))
    'continue)
   ((string-prefix? "/trace " line)
    (show-traces tracer #f (trimmed-command-argument line "/trace "))
    'continue)
   ((string=? line "/compact") 'compact)
   ((string=? line "/recover") (show-recovery tracer) 'continue)
   ((string=? line "/recover retry") 'recover-retry)
   ((string=? line "/recover discard")
    (recovery-clear! (runtime-state-directory tracer))
    (display "Interrupted tool record discarded; no tool was executed.\n")
    'continue)
   ((string=? line "/session") (show-session session) 'continue)
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
    "switch" "enable" "disable" "always" "start" "stop" "add"
    "implement" "create" "write" "refactor" "remove" "rename" "patch"))

(define (explicit-live-change-request? text)
  (let ((lower (string-downcase text)))
    (any (lambda (word) (string-contains lower word))
         live-change-intent-words)))

(define (read-user-line prompt)
  (if (isatty? (current-input-port))
      (readline prompt)
      (get-line (current-input-port))))

(define (terminal-settings)
  (catch #t
    (lambda ()
      (let* ((port (open-pipe* OPEN_READ "/bin/stty" "-g"))
             (value (string-trim-both (get-string-all port)))
             (status (close-pipe port)))
        (and (= (status:exit-val status) 0)
             (not (string-null? value))
             value)))
    (lambda _ #f)))

(define (read-approval-key prompt)
  (display prompt)
  (force-output)
  (if (not (isatty? (current-input-port)))
      (read-user-line "")
      (let ((saved (terminal-settings)))
        (if (not saved)
            (read-user-line "")
            (let ((status
                   (system* "/bin/stty" "-icanon" "min" "1" "time" "0"
                            "-echo")))
              (if (not (= (status:exit-val status) 0))
                  (read-user-line "")
                  (let ((answer
                         (dynamic-wind
                           (lambda () #t)
                           (lambda () (read-char (current-input-port)))
                           (lambda () (system* "/bin/stty" saved)))))
                    (unless (eof-object? answer) (write-char answer))
                    (newline)
                    answer)))))))

(define (confirm-shell command)
  (format #t "\nShell requests:\n  ~a~%" command)
  (force-output)
  (let ((answer (read-approval-key "Approve this command? [y/N] ")))
    (cond
     ((char? answer) (char-ci=? answer #\y))
     ((string? answer)
      (member (string-downcase (string-trim-both answer)) '("y" "yes")))
     (else #f))))

(define (retry-interrupted-tool! runtime tracer)
  (let* ((state-directory (runtime-state-directory tracer))
         (pending (recovery-read state-directory)))
    (if (not pending)
        (begin
          (display "No interrupted tool call is pending.\n")
          #f)
        (let* ((generation (runtime-current runtime))
               (name (json-object-ref pending "tool"))
               (arguments (json-object-ref pending "arguments"))
               (enabled
                (map tool-name (generation-ref generation 'agent-tools))))
          (unless (member name enabled)
            (error "the interrupted tool is no longer enabled" name))
          (when (member name '("live_eval" "extension"))
            (error
             "live mutations cannot be replayed because their outcome is ambiguous; inspect the generation, then discard this record"
             name))
          (format #t
                  "Retrying interrupted ~a call explicitly. It may have partially executed before interruption.\n"
                  name)
          (let* ((span
                  (trace-start!
                   tracer (string-append "tool." name ".recovery") "TOOL"
                   `((generation.id . ,(generation-id generation))
                     (tool.name . ,name)
                     (recovery.retry . #t)
                     (input.value . ,(json-write arguments)))))
                 (outcome
                  (if (string=? name "traces")
                      (execute-traces tracer arguments)
                      (execute-tool
                       name arguments (getcwd)
                       (generation-ref generation 'agent-shell-policy)
                       confirm-shell)))
                 (output (tool-result-output outcome)))
            (trace-end!
             span (if (tool-result-success? outcome) "OK" "ERROR")
             `((output.value . ,output)))
            (runtime-record!
             runtime 'tool-recovery-retried
             `((generation . ,(generation-id generation))
               (tool . ,name)
               (success . ,(tool-result-success? outcome))
               (output . ,output)))
            (recovery-clear! state-directory)
            (format #t "Recovery result: ~a\n" output)
            (make-message
             "system"
             (format #f
                     "An interrupted ~a tool call was explicitly retried. Result: ~a. The original model continuation was lost; verify before relying on it."
                     name output)))))))

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
                      (begin
                        ;; This write-ahead record is deliberately retained if
                        ;; cancellation or process death interrupts execution.
                        (recovery-write!
                         (runtime-state-directory tracer)
                         name (tool-call-arguments call)
                         (generation-id generation))
                        (catch #t
                          (lambda ()
                            (cond
                             ((string=? name "live_eval")
                              (execute-live-eval
                               runtime generation (tool-call-arguments call)
                               (assistant-explained-change? messages)))
                             ((string=? name "extension")
                              (execute-extension
                               runtime generation (tool-call-arguments call)))
                             ((string=? name "traces")
                              (execute-traces tracer (tool-call-arguments call)))
                             (else
                              (execute-tool
                               name
                               (tool-call-arguments call)
                               (getcwd)
                               (generation-ref generation 'agent-shell-policy)
                               confirm-shell))))
                          (lambda (key . arguments)
                            (if (cancelled? key)
                                (begin
                                  (trace-end!
                                   span "CANCELLED"
                                   `((error.message . "tool interrupted; recovery record retained")))
                                  (apply throw key arguments))
                                (make-tool-result
                                 #f (format #f "tool failed (~a): ~s" key arguments))))))))
                 (ok? (tool-result-success? outcome))
                 (output (tool-result-output outcome)))
            (trace-end! span (if ok? "OK" "ERROR")
                        `((output.value . ,output)))
            (runtime-record!
             runtime 'tool-result
             `((generation . ,(generation-id generation))
               (tool . ,name)
               (output . ,output)))
            (when enabled?
              (recovery-clear! (runtime-state-directory tracer)))
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
                   (json-object-ref root "eval_count" #f))))
         (prompt-details
          (and openai-usage
               (json-object? openai-usage)
               (json-object-ref openai-usage "prompt_tokens_details" #f)))
         (completion-details
          (and openai-usage
               (json-object? openai-usage)
               (json-object-ref openai-usage "completion_tokens_details" #f)))
         (cached
          (and prompt-details
               (json-object? prompt-details)
               (json-object-ref prompt-details "cached_tokens" #f)))
         (cache-write
          (and prompt-details
               (json-object? prompt-details)
               (json-object-ref prompt-details "cache_write_tokens" #f)))
         (reasoning
          (and completion-details
               (json-object? completion-details)
               (json-object-ref completion-details "reasoning_tokens" #f)))
         (metric
          (lambda (name)
            (and (json-object? root) (json-object-ref root name #f)))))
    (append
     (if prompt `((llm.token_count.prompt . ,prompt)) '())
     (if output `((llm.token_count.completion . ,output)) '())
     (if cached `((llm.token_count.prompt_cached . ,cached)) '())
     (if cache-write `((llm.token_count.prompt_cache_write . ,cache-write)) '())
     (if reasoning `((llm.token_count.reasoning . ,reasoning)) '())
     (if (metric "total_duration")
         `((llm.total_duration_ns . ,(metric "total_duration"))) '())
     (if (metric "load_duration")
         `((llm.load_duration_ns . ,(metric "load_duration"))) '())
     (if (metric "prompt_eval_duration")
         `((llm.prompt_eval_duration_ns . ,(metric "prompt_eval_duration"))) '())
     (if (metric "eval_duration")
         `((llm.eval_duration_ns . ,(metric "eval_duration"))) '()))))

(define (messages-character-count messages)
  (fold (lambda (message total)
          (+ total (string-length (json-write message))))
        0 messages))

(define (complete-with-trace tracer parent generation-id provider model base-url
                             api-key messages enabled-tools stream? thinking
                             keep-alive prompt-cache-key round
                             prompt-attributes)
  (let ((span
         (trace-start!
          tracer (string-append (symbol->string provider) ".chat") "LLM"
          (append
           `((generation.id . ,generation-id)
             (llm.model_name . ,model)
             (llm.provider . ,(symbol->string provider))
             (llm.round . ,round)
             (input.value . ,(json-write (apply json-array messages))))
           prompt-attributes)
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
                stream? thinking keep-alive prompt-cache-key
                on-content on-thinking)))
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
        (trace-end! span (if (cancelled? key) "CANCELLED" "ERROR")
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
         ;; Mutation tools are absent unless this user turn contains explicit
         ;; change intent. This prevents opportunistic "helpful" writes when
         ;; the user only asked for information or content in the response.
         (enabled-tools
          (filter
           (lambda (name)
             (or (not (member name '("live_eval" "write" "edit")))
                 (explicit-live-change-request? line)))
           configured-tools))
         (max-rounds
          (generation-ref generation 'agent-max-tool-rounds))
         (stream? (generation-ref generation 'agent-stream?))
         (thinking (generation-ref generation 'agent-thinking))
         (keep-alive (generation-ref generation 'agent-keep-alive))
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
         (context-messages
          (if (null? context-paths)
              '()
              (list
               (make-message
                "system"
                (string-append
                 "Authoritative project context selected by agent-select-context "
                 "for this turn. Prefer it over earlier answers when they conflict.\n\n"
                 context-text)))))
         (user-message (make-message "user" transformed-line))
         (cache-prefix (append (list system) history))
         (cache-cohort
          (if (explicit-live-change-request? line) "mutation" "normal"))
         (prompt-cache-key
          (string-append
           "shift-" (generation-fingerprint generation) "-" cache-cohort))
         (prompt-attributes
          `((prompt.cache.cohort
             . ,cache-cohort)
            (prompt.cache.key . ,prompt-cache-key)
            (prompt.cache.prefix_messages
             . ,(prompt-cache-prefix-count history))
            (prompt.cache.prefix_chars
             . ,(messages-character-count cache-prefix))
            (prompt.cache.dynamic_context_chars
             . ,(messages-character-count context-messages))
            (prompt.cache.tool_count . ,(length enabled-tools))))
         (working
          (build-provider-messages
           system history context-messages user-message)))
    (let loop ((messages working) (round 0))
      (let* ((outcome
              (complete-with-trace
               tracer parent (generation-id generation)
               provider model base-url api-key messages
               enabled-tools stream? thinking keep-alive prompt-cache-key round
               prompt-attributes))
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
              ;; Drop the runtime-owned system prompt and this turn's selected
              ;; context while retaining the prior history and new turn tail.
              (list
               (persist-provider-turn
                history (length context-messages) with-assistant)
               reply))
            (begin
              (when (>= round max-rounds)
                (error "tool round limit reached" max-rounds))
              (loop
               (execute-tool-calls
                runtime tracer parent generation provider calls with-assistant
                enabled-tools)
               (+ round 1))))))))

(define (summarize-compaction generation prefix)
  (if (string=? (generation-ref generation 'agent-model) "demo")
      (format #f "Compacted ~a earlier messages from the demo session."
              (length prefix))
      (let* ((provider (generation-ref generation 'agent-provider))
             (key-environment
              (generation-ref generation 'agent-api-key-environment))
             (api-key (and key-environment (getenv key-environment)))
             (keep-alive (generation-ref generation 'agent-keep-alive))
             (completion
              (provider-complete
               provider
               (generation-ref generation 'agent-model)
               (generation-ref generation 'agent-base-url)
               api-key
               (list
                (make-message
                 "system"
                 (string-append
                  "Summarize the earlier agent conversation for safe continuation. "
                  "Preserve user intent, decisions, exact file paths, generation changes, "
                  "tool outcomes, unresolved work, and safety constraints. Do not claim "
                  "success without a recorded tool result. Return only the compact summary."))
                (make-message
                 "user" (json-write (apply json-array prefix))))
               '() #f #f keep-alive
               (string-append
                "shift-" (generation-fingerprint generation) "-compaction")
               (lambda _ #t) (lambda _ #t))))
        (let ((summary (or (completion-content completion) "")))
          (when (string-null? (string-trim-both summary))
            (error "compaction model returned an empty summary"))
          summary))))

(define (compact-history! runtime tracer history force?)
  (let* ((generation (runtime-current runtime))
         (threshold
          (generation-ref generation 'agent-compaction-threshold))
         (keep-recent
          (generation-ref generation 'agent-compaction-keep-recent)))
    (if (not (or force? (history-needs-compaction? history threshold)))
        (begin
          (when force?
            (format #t "History has ~a messages; nothing is old enough to compact.\n"
                    (length history)))
          history)
        (let ((prefix (compaction-prefix history keep-recent)))
          (if (null? prefix)
              history
              (let ((span
                     (trace-start!
                      tracer "session.compact" "AGENT"
                      `((generation.id . ,(generation-id generation))
                        (compaction.before_messages . ,(length history))
                        (compaction.prefix_messages . ,(length prefix))
                        (compaction.keep_recent . ,keep-recent)))))
                (dynamic-wind
                  (lambda () (set! turn-active? #t))
                  (lambda ()
                    (catch #t
                      (lambda ()
                        (let* ((summary (summarize-compaction generation prefix))
                               (compacted
                                (compact-history-with-summary
                                 history summary keep-recent)))
                          (trace-end!
                           span "OK"
                           `((generation.id . ,(generation-id generation))
                             (compaction.after_messages . ,(length compacted))
                             (output.value . ,summary)))
                          (runtime-record!
                           runtime 'session-compacted
                           `((generation . ,(generation-id generation))
                             (before-messages . ,(length history))
                             (after-messages . ,(length compacted))))
                          (format #t "compacted ~a messages to ~a · generation ~a\n"
                                  (length history) (length compacted)
                                  (generation-id generation))
                          compacted))
                      (lambda (key . arguments)
                        (trace-end!
                         span (if (cancelled? key) "CANCELLED" "ERROR")
                         `((error.message . ,(format #f "~s" arguments))))
                        (format (current-error-port)
                                "compaction failed; original history retained: ~s~%"
                                arguments)
                        history)))
                  (lambda () (set! turn-active? #f)))))))))

(define (perform-turn! runtime tracer history line turn-count)
  (let* ((generation (runtime-current runtime))
         (span
          (trace-start!
           tracer "agent.turn" "AGENT"
           `((generation.id . ,(generation-id generation))
             (turn.number . ,turn-count)
             (input.value . ,line)))))
    (record-input! runtime generation turn-count line)
    (dynamic-wind
      (lambda () (set! turn-active? #t))
      (lambda ()
        (catch #t
          (lambda ()
            (let ((new-history
                   (if (string=? (generation-ref generation 'agent-model) "demo")
                       (demo-turn! runtime generation history line turn-count)
                       (provider-turn!
                        runtime tracer span generation history line turn-count))))
              (trace-end! span "OK" `((output.value . ,(cadr new-history))))
              (list 'ok (car new-history))))
          (lambda (key . arguments)
            (if (cancelled? key)
                (begin
                  (trace-end! span "CANCELLED"
                              '((error.message . "cancelled by user")))
                  (runtime-record!
                   runtime 'turn-cancelled
                   `((generation . ,(generation-id generation))
                     (turn . ,turn-count)))
                  (display "turn cancelled; conversation state is unchanged.\n")
                  #f)
                (let ((detail (format #f "~s: ~s" key arguments)))
                  (trace-end! span "ERROR" `((error.message . ,detail)))
                  (format (current-error-port) "turn failed: ~a~%" detail)
                  #f)))))
      (lambda () (set! turn-active? #f)))))

(define (repl runtime tracer watch? session checkpoint! initial-prompt)
  (show-banner runtime watch? session)
  (force-output)
  (let loop ((turn-count (if session (session-next-turn session) 1))
             (history (if session (session-history session) '()))
             (pending initial-prompt))
    (if pending
        (let ((result
               (perform-turn! runtime tracer history pending turn-count)))
          (if result
              (let ((next-turn (+ turn-count 1))
                    (next-history
                     (compact-history! runtime tracer (cadr result) #f)))
                (checkpoint! next-history next-turn)
                (loop next-turn next-history #f))
              (loop turn-count history #f)))
        (let ((line (read-user-line "shift> ")))
      (cond
       ((eof-object? line)
        (checkpoint! history turn-count)
        (newline))
       ((string-null? (string-trim-both line))
        (loop turn-count history #f))
       ((string-prefix? "/" line)
        (case (handle-command runtime tracer session line)
          ((quit)
           (checkpoint! history turn-count)
           #t)
          ((reset)
           (display "Conversation state cleared.\n")
           (checkpoint! '() 1)
           (loop 1 '() #f))
          ((compact)
           (let ((compacted (compact-history! runtime tracer history #t)))
             (checkpoint! compacted turn-count)
             (loop turn-count compacted #f)))
          ((recover-retry)
           (let ((recovery-message
                  (try-transition
                   "tool recovery"
                   (lambda () (retry-interrupted-tool! runtime tracer)))))
             (let ((recovered-history
                    (if recovery-message
                        (append history (list recovery-message))
                        history)))
               (checkpoint! recovered-history turn-count)
               (loop turn-count recovered-history #f))))
          (else
           (checkpoint! history turn-count)
           (loop turn-count history #f))))
       (else
        (let ((result (perform-turn! runtime tracer history line turn-count)))
          (if result
              (let ((next-turn (+ turn-count 1))
                    (next-history
                     (compact-history! runtime tracer (cadr result) #f)))
                (checkpoint! next-history next-turn)
                (loop next-turn next-history #f))
              (loop turn-count history #f)))))))))

(define (main args)
  (call-with-values
      (lambda () (parse-arguments args))
    (lambda (agent-path state-directory watch? requested-session-name session-mode
             list? initial-prompt)
      (unless (and agent-path state-directory)
        (usage)
        (exit 2))
      (when list?
        (let ((names (list-session-names state-directory)))
          (if (null? names)
              (display "No durable sessions.\n")
              (for-each (lambda (name) (display name) (newline)) names)))
        (exit 0))
      (let* ((session
              (and requested-session-name
                   (try-transition
                    "session open"
                    (lambda ()
                      (open-session!
                       state-directory requested-session-name session-mode)))))
             (runtime-state-directory
              (if session (session-directory session) state-directory))
             (runtime
              (and
               (or (not requested-session-name) session)
               (try-transition
                "startup"
                (lambda ()
                  (make-runtime
                   agent-path runtime-state-directory
                   (if session (session-patches session) '())
                   (if session (session-generation-id session) 1)
                   (and session (session-fingerprint session)))))))
             (tracer
              (and runtime
                   (make-tracer
                    runtime-state-directory
                    (or (getenv "SHIFT_OTEL_ENDPOINT")
                        (getenv "LISP_AGENT_OTEL_ENDPOINT")
                        (getenv "PHOENIX_COLLECTOR_ENDPOINT"))
                    (and session (session-id session))
                    (and session (session-name session))))))
        (unless runtime (exit 1))
        (install-cancellation-handler!)
        (let ((checkpoint-history
               (if session (session-history session) '()))
              (checkpoint-turn
               (if session (session-next-turn session) 1)))
          (define (checkpoint! history next-turn)
            (set! checkpoint-history history)
            (set! checkpoint-turn next-turn)
            (when session
              (save-session! session runtime history next-turn)))
          (when session
            (runtime-record!
             runtime
             (if (session-resumed? session) 'session-resumed 'session-created)
             `((session . ,(session-name session))
               (session-id . ,(session-id session))
               (turn . ,checkpoint-turn)))
            (checkpoint! checkpoint-history checkpoint-turn))
          (let ((stop-watcher!
                 (if watch?
                     (start-agent-watcher!
                      runtime
                      (lambda ()
                        (checkpoint! checkpoint-history checkpoint-turn)))
                     (lambda () #t))))
          (dynamic-wind
            (lambda () #t)
            (lambda ()
              (when (recovery-read runtime-state-directory)
                (display
                 "\n! interrupted tool record found; use /recover before continuing.\n"))
              (repl runtime tracer watch? session checkpoint! initial-prompt))
            (lambda ()
              (stop-watcher!)
              (trace-close! tracer)
              (when session (close-session! session))))))))))

(main (cdr (command-line)))
