(define-module (live-agent main)
  #:use-module (ice-9 exceptions)
  #:use-module (ice-9 format)
  #:use-module (ice-9 readline)
  #:use-module (live-agent json)
  #:use-module (live-agent generation)
  #:use-module (live-agent provider)
  #:use-module (live-agent runtime)
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
    "  /reset            clear conversation state\n"
    "  /help             show this help\n"
    "  /quit             exit\n")))

(define (show-generation runtime)
  (let ((generation (runtime-current runtime)))
    (format #t
            "generation ~a  fingerprint ~a~%agent ~a  model ~a~%tools ~s  shell ~s  patches ~a~%source ~a~%"
            (generation-id generation)
            (generation-fingerprint generation)
            (generation-ref generation 'agent-name)
            (generation-ref generation 'agent-model)
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

(define (handle-command runtime line)
  (cond
   ((string=? line "/help") (show-help) 'continue)
   ((string=? line "/show") (show-generation runtime) 'continue)
   ((string=? line "/generations") (show-generations runtime) 'continue)
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

(define (confirm-shell command)
  (format #t "\nShell requests:\n  ~a~%" command)
  (let ((answer (readline "Approve this command? [y/N] ")))
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
    (append history
            (list (make-message "user" line)
                  (make-message "assistant" reply)))))

(define (execute-tool-calls runtime generation calls messages enabled-tools)
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
          (let ((output
                 (execute-tool
                  name
                  (tool-call-arguments call)
                  (getcwd)
                  (generation-ref generation 'agent-shell-policy)
                  confirm-shell)))
            (runtime-record!
             runtime 'tool-result
             `((generation . ,(generation-id generation))
               (tool . ,name)
               (output . ,output)))
            (loop (cdr remaining)
                  (append result
                          (list
                           (make-tool-result-message
                            (tool-call-id call)
                            output)))))))))

(define (provider-turn! runtime generation history line turn-count)
  (let* ((model (generation-ref generation 'agent-model))
         (base-url (generation-ref generation 'agent-base-url))
         (key-environment
          (generation-ref generation 'agent-api-key-environment))
         (api-key (and key-environment (getenv key-environment)))
         (enabled-tools
          (map tool-name (generation-ref generation 'agent-tools)))
         (max-rounds
          (generation-ref generation 'agent-max-tool-rounds))
         (system
          (make-message
           "system" (generation-ref generation 'agent-system-prompt)))
         (working
          (append (list system) history (list (make-message "user" line)))))
    (let loop ((messages working) (round 0))
      (let* ((completion
              (provider-complete model base-url api-key messages enabled-tools))
             (calls (completion-tool-calls completion))
             (with-assistant
              (append messages (list (completion-assistant-message completion)))))
        (if (null? calls)
            (let ((reply (or (completion-content completion) "")))
              (record-output! runtime generation turn-count reply)
              (display reply)
              (newline)
              ;; Drop the current system message. The active generation supplies
              ;; a fresh one at the start of every user turn.
              (cdr with-assistant))
            (begin
              (when (>= round max-rounds)
                (error "tool round limit reached" max-rounds))
              (loop
               (execute-tool-calls
                runtime generation calls with-assistant enabled-tools)
               (+ round 1))))))))

(define (perform-turn! runtime history line turn-count)
  (let ((generation (runtime-current runtime)))
    (record-input! runtime generation turn-count line)
    (with-exception-handler
        (lambda (exception)
          (format (current-error-port) "turn failed: ~a~%"
                  (exception-detail exception))
          #f)
      (lambda ()
        (let ((new-history
               (if (string=? (generation-ref generation 'agent-model) "demo")
                   (demo-turn! runtime generation history line turn-count)
                   (provider-turn! runtime generation history line turn-count))))
          (list 'ok new-history)))
      #:unwind? #t)))

(define (repl runtime)
  (show-generation runtime)
  (display "Enter text to exercise the live image, or /help.\n")
  (let loop ((turn-count 1) (history '()))
    (let ((line (readline "live-agent> ")))
      (cond
       ((eof-object? line) (newline))
       ((string-null? (string-trim-both line)) (loop turn-count history))
       ((string-prefix? "/" line)
        (case (handle-command runtime line)
          ((quit) #t)
          ((reset)
           (display "Conversation state cleared.\n")
           (loop 1 '()))
          (else (loop turn-count history))))
       (else
        (let ((result (perform-turn! runtime history line turn-count)))
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
      (let ((runtime
             (try-transition
              "startup"
              (lambda () (make-runtime agent-path state-directory)))))
        (unless runtime (exit 1))
        (repl runtime)))))

(main (cdr (command-line)))
