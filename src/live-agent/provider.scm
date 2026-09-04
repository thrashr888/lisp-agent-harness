(define-module (live-agent provider)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-9)
  #:use-module (live-agent json)
  #:export (tool-call?
            tool-call-id
            tool-call-name
            tool-call-arguments
            completion?
            completion-content
            completion-thinking
            completion-tool-calls
            completion-assistant-message
            completion-usage
            make-message
            make-tool-result-message
            make-ollama-request
            parse-completion-response
            parse-ollama-response
            provider-complete))

(define-record-type <tool-call>
  (make-tool-call id name arguments raw-arguments)
  tool-call?
  (id tool-call-id)
  (name tool-call-name)
  (arguments tool-call-arguments)
  (raw-arguments tool-call-raw-arguments))

(define-record-type <completion>
  (make-completion content thinking tool-calls assistant-message usage)
  completion?
  (content completion-content)
  (thinking completion-thinking)
  (tool-calls completion-tool-calls)
  (assistant-message completion-assistant-message)
  (usage completion-usage))

(define (make-message role content)
  (json-object (cons "role" role) (cons "content" content)))

(define (make-tool-result-message provider call-id tool-name content)
  (if (eq? provider 'ollama)
      (json-object
       (cons "role" "tool")
       (cons "tool_name" tool-name)
       (cons "content" content))
      (json-object
       (cons "role" "tool")
       (cons "tool_call_id" call-id)
       (cons "content" content))))

(define (function-tool name description properties required)
  (json-object
   (cons "type" "function")
   (cons "function"
         (json-object
          (cons "name" name)
          (cons "description" description)
          (cons "parameters"
                (json-object
                 (cons "type" "object")
                 (cons "properties" properties)
                 (cons "required" (apply json-array required))
                 (cons "additionalProperties" #f)))))))

(define (string-parameter description)
  (json-object (cons "type" "string") (cons "description" description)))

(define (tool-schema name)
  (cond
   ((string=? name "read")
    (json-object
     (cons "type" "function")
     (cons "function"
           (json-object
            (cons "name" "read")
            (cons "description"
                  (string-append
                   "Read one exact UTF-8 text file inside the current project. "
                   "Try the most likely path first; only try another path if it fails."))
            (cons "parameters"
                  (json-object
                   (cons "type" "object")
                   (cons "properties"
                         (json-object
                          (cons "path"
                                (json-object
                                 (cons "type" "string")
                                 (cons "description" "Project-relative file path")))))
                   (cons "required" (json-array "path"))
                   (cons "additionalProperties" #f)))))))
   ((string=? name "rg")
    (function-tool
     "rg"
     (string-append
      "Search project text with ripgrep without invoking a shell. Queries are "
      "literal by default, so punctuation such as Scheme parentheses is safe. "
      "For Guile module imports, search the literal forms #:use-module and "
      "(use-modules separately. "
      "Set regex to true only when regular-expression behavior is intentional. "
      "Results are bounded and project-confined.")
     (json-object
      (cons "query" (string-parameter "Text to find; interpreted literally unless regex is true"))
      (cons "path" (string-parameter "Optional project-relative file or directory; defaults to ."))
      (cons "glob" (string-parameter "Optional ripgrep glob such as *.scm"))
      (cons "regex"
            (json-object
             (cons "type" "boolean")
             (cons "description" "Interpret query as a regular expression; defaults to false"))))
     '("query")))
   ((string=? name "write")
    (function-tool
     "write"
     "Atomically create or replace one UTF-8 text file inside the project. Parent directories must already exist."
     (json-object
      (cons "path" (string-parameter "Project-relative file path"))
      (cons "content" (string-parameter "Complete new file content")))
     '("path" "content")))
   ((string=? name "edit")
    (function-tool
     "edit"
     "Atomically edit one project text file by exact replacement. By default old_text must occur exactly once."
     (json-object
      (cons "path" (string-parameter "Project-relative file path"))
      (cons "old_text" (string-parameter "Exact text to replace"))
      (cons "new_text" (string-parameter "Replacement text"))
      (cons "replace_all"
            (json-object
             (cons "type" "boolean")
             (cons "description" "Replace every occurrence; defaults to false"))))
     '("path" "old_text" "new_text")))
   ((string=? name "shell")
    (json-object
     (cons "type" "function")
     (cons "function"
           (json-object
            (cons "name" "shell")
            (cons "description"
                  (string-append
                   "Run a shell command after explicit user approval. Use only "
                   "when read cannot accomplish the task; do not use shell to "
                   "discover or read a conventional project file."))
            (cons "parameters"
                  (json-object
                   (cons "type" "object")
                   (cons "properties"
                         (json-object
                          (cons "command"
                                (json-object
                                 (cons "type" "string")
                                 (cons "description" "Command to run from the project root")))))
                   (cons "required" (json-array "command"))
                   (cons "additionalProperties" #f)))))))
   ((string=? name "live_eval")
    (function-tool
     "live_eval"
     (string-append
      "Transactionally change your live Scheme behavior. Before calling, explain "
      "to the user what binding will change, why, and the expected effect. Top-level "
      "forms are limited to define, define*, set!, or begin and may target only "
      "agent-* or extension-* bindings. The next user turn sees the generation; "
      "/rollback undoes it. After the result, explain the before/after generations "
      "and whether the expected behavior was achieved or still needs a retry.")
     (json-object
      (cons "expression"
            (string-parameter "One or more restricted Scheme definitions or assignments"))
      (cons "summary"
            (string-parameter "Plain-language description of exactly what changes"))
      (cons "expected_behavior"
            (string-parameter "Observable behavior expected on the next user turn")))
     '("expression" "summary" "expected_behavior")))
   ((string=? name "traces")
    (function-tool
     "traces"
     (string-append
      "Inspect this running session's own completed trace spans. Use this to "
      "verify tool outcomes, errors, generation identity, context selection, "
      "compaction, and cancellation instead of trusting narration. Results "
      "are session-scoped and bounded. Search the complete durable trace after "
      "compaction, then fetch an exact span_id when full stored attributes are needed.")
     (json-object
      (cons "query"
            (json-object
             (cons "type" "string")
             (cons "maxLength" 256)
             (cons "description" "Case-insensitive literal search across stored span JSON")))
      (cons "span_id"
            (json-object
             (cons "type" "string")
             (cons "maxLength" 256)
             (cons "description" "Exact span ID to retrieve with full stored attributes")))
      (cons "name" (string-parameter "Exact span name filter, such as agent.turn"))
      (cons "kind" (string-parameter "Exact OpenInference kind filter"))
      (cons "status" (string-parameter "Exact status filter"))
      (cons "generation"
            (json-object
             (cons "type" "integer")
             (cons "minimum" 1)))
      (cons "turn"
            (json-object
             (cons "type" "integer")
             (cons "minimum" 1)))
      (cons "limit"
            (json-object
             (cons "type" "integer")
             (cons "minimum" 1)
             (cons "maximum" 50)
             (cons "description" "Most recent spans to return; defaults to 12")))
      (cons "errors_only"
            (json-object
             (cons "type" "boolean")
             (cons "description" "Only return ERROR or CANCELLED spans"))))
     '()))
   ((string=? name "extension")
    (function-tool
     "extension"
     (string-append
      "Manage persistent Scheme extension artifacts. Actions: list; create a named "
      "artifact from expression without enabling it; load it into a new generation; "
      "disable its exact patch; or export all active live patches under a name. "
      "Explain user-visible changes before create, load, disable, or export.")
     (json-object
      (cons "action"
            (json-object
             (cons "type" "string")
             (cons "enum" (json-array "list" "create" "load" "disable" "export"))))
      (cons "name" (string-parameter "Artifact name for actions other than list"))
      (cons "expression"
            (string-parameter "Restricted Scheme patch required by create"))
      (cons "description"
            (string-parameter "Short purpose recorded in the artifact header")))
     '("action")))
   (else (error "unknown live tool" name))))

(define (without-trailing-slash value)
  (let loop ((end (string-length value)))
    (if (and (> end 0) (char=? (string-ref value (- end 1)) #\/))
        (loop (- end 1))
        (substring value 0 end))))

(define (call-with-temporary-content template content procedure)
  (let* ((port (mkstemp template))
         (path (port-filename port)))
    (dynamic-wind
      (lambda ()
        (display content port)
        (force-output port)
        (close-port port))
      (lambda () (procedure path))
      (lambda ()
        (when (file-exists? path) (delete-file path))))))

(define (curl-post-json endpoint api-key payload)
  (when (and api-key
             (or (string-index api-key #\newline)
                 (string-index api-key #\return)))
    (error "API key contains an invalid newline"))
  (let ((headers
         (string-append
          "Content-Type: application/json\n"
          (if (and api-key (not (string-null? api-key)))
              (string-append "Authorization: Bearer " api-key "\n")
              ""))))
    ;; Keep credentials, prompts, and tool results out of the process argument
    ;; list. mkstemp creates private files; dynamic-wind removes them afterward.
    (call-with-temporary-content
     "/tmp/live-agent-request-XXXXXX" payload
     (lambda (payload-path)
       (call-with-temporary-content
        "/tmp/live-agent-headers-XXXXXX" headers
        (lambda (headers-path)
          (let* ((port
                  (open-pipe*
                   OPEN_READ "curl"
                   "-sS" "--fail-with-body"
                   "--connect-timeout" "10"
                   "--max-time" "120"
                   "--max-filesize" "4194304"
                   "-H" (string-append "@" headers-path)
                   "--data-binary" (string-append "@" payload-path)
                   endpoint))
                 (response (get-string-all port))
                 (status (close-pipe port))
                 (exit-code (status:exit-val status)))
            (unless (and exit-code (= exit-code 0))
              (error "provider request failed" exit-code response))
            response)))))))

(define (curl-post-json-lines endpoint api-key payload consume-line)
  (when (and api-key
             (or (string-index api-key #\newline)
                 (string-index api-key #\return)))
    (error "API key contains an invalid newline"))
  (let ((headers
         (string-append
          "Content-Type: application/json\n"
          (if (and api-key (not (string-null? api-key)))
              (string-append "Authorization: Bearer " api-key "\n")
              ""))))
    (call-with-temporary-content
     "/tmp/live-agent-request-XXXXXX" payload
     (lambda (payload-path)
       (call-with-temporary-content
        "/tmp/live-agent-headers-XXXXXX" headers
        (lambda (headers-path)
          (let ((port
                 (open-pipe*
                  OPEN_READ "curl"
                  "-sS" "-N" "--fail-with-body"
                  "--connect-timeout" "10"
                  "--max-time" "120"
                  "-H" (string-append "@" headers-path)
                  "--data-binary" (string-append "@" payload-path)
                  endpoint)))
            (let loop ()
              (let ((line (get-line port)))
                (unless (eof-object? line)
                  (unless (string-null? (string-trim-both line))
                    (consume-line line))
                  (loop))))
            (let* ((status (close-pipe port))
                   (exit-code (status:exit-val status)))
              (unless (and exit-code (= exit-code 0))
                (error "provider streaming request failed" exit-code))))))))))

(define (parse-tool-call value)
  (let* ((function (json-object-ref value "function"))
         (raw-arguments (json-object-ref function "arguments" "{}"))
         (arguments (json-read raw-arguments)))
    (unless (json-object? arguments)
      (error "tool arguments must decode to a JSON object" raw-arguments))
    (make-tool-call
     (json-object-ref value "id")
     (json-object-ref function "name")
     arguments
     raw-arguments)))

(define (tool-calls->json calls)
  (apply
   json-array
   (map
    (lambda (call)
      (json-object
       (cons "id" (tool-call-id call))
       (cons "type" "function")
       (cons "function"
             (json-object
              (cons "name" (tool-call-name call))
              (cons "arguments" (tool-call-raw-arguments call))))))
    calls)))

(define (parse-completion-response text)
  (let* ((root (json-read text))
         (provider-error (json-object-ref root "error" #f)))
    (when provider-error
      (error "provider returned an error"
             (if (json-object? provider-error)
                 (json-object-ref provider-error "message" provider-error)
                 provider-error)))
    (let* ((choices (json-object-ref root "choices"))
           (choice-items (json-array-items choices)))
      (when (null? choice-items) (error "provider returned no choices"))
      (let* ((message (json-object-ref (car choice-items) "message"))
             (content-value (json-object-ref message "content" json-null))
             (content (if (eq? content-value json-null) #f content-value))
             (calls-value
              (json-object-ref message "tool_calls" (json-array)))
             (calls (map parse-tool-call (json-array-items calls-value)))
             (assistant
              (apply
               json-object
               (append
                (list
                 (cons "role" "assistant")
                 (cons "content" (if content content json-null)))
                (if (null? calls)
                    '()
                    (list (cons "tool_calls" (tool-calls->json calls))))))))
        (make-completion content #f calls assistant root)))))

(define (parse-ollama-tool-call value)
  (let* ((function (json-object-ref value "function"))
         (arguments-value (json-object-ref function "arguments" (json-object)))
         (arguments
          (if (string? arguments-value)
              (json-read arguments-value)
              arguments-value))
         (raw-arguments
          (if (string? arguments-value)
              arguments-value
              (json-write arguments-value))))
    (unless (json-object? arguments)
      (error "tool arguments must be a JSON object" arguments-value))
    (make-tool-call
     (json-object-ref value "id" (string-append "call_" (number->string (random 1000000000))))
     (json-object-ref function "name")
     arguments
     raw-arguments)))

(define (tool-calls->ollama-json calls)
  (apply
   json-array
   (map
    (lambda (call)
      (json-object
       (cons "id" (tool-call-id call))
       (cons "type" "function")
       (cons "function"
             (json-object
              (cons "name" (tool-call-name call))
              (cons "arguments" (tool-call-arguments call))))))
    calls)))

(define (make-ollama-request model messages tool-names stream? thinking keep-alive)
  (let* ((tool-values (map tool-schema tool-names))
         (fields
          (append
           (list
            (cons "model" model)
            (cons "messages" (apply json-array messages))
            (cons "stream" stream?)
            (cons "keep_alive" keep-alive)
            (cons "think"
                  (if (symbol? thinking)
                      (symbol->string thinking)
                      thinking)))
           (if (null? tool-values)
               '()
               (list (cons "tools" (apply json-array tool-values)))))))
    (apply json-object fields)))

(define (parse-ollama-response text)
  (let* ((root (json-read text))
         (provider-error (json-object-ref root "error" #f)))
    (when provider-error
      (error "provider returned an error" provider-error))
    (let* ((message (json-object-ref root "message"))
           (content (json-object-ref message "content" ""))
           (thought (json-object-ref message "thinking" ""))
           (calls
            (map parse-ollama-tool-call
                 (json-array-items
                  (json-object-ref message "tool_calls" (json-array))))))
      (make-completion content thought calls message root))))

(define (provider-complete-ollama model base-url api-key messages tool-names
                                  stream? thinking keep-alive
                                  on-content on-thinking)
  (let* ((payload
          (json-write
           (make-ollama-request
            model messages tool-names stream? thinking keep-alive)))
         (endpoint (string-append (without-trailing-slash base-url) "/api/chat")))
    (if stream?
        (let ((content-port (open-output-string))
              (thinking-port (open-output-string))
              (calls '())
              (usage (json-object)))
          (curl-post-json-lines
           endpoint api-key payload
           (lambda (line)
             (let* ((root (json-read line))
                    (provider-error (json-object-ref root "error" #f)))
               (when provider-error
                 (error "provider returned an error" provider-error))
               (let* ((message (json-object-ref root "message" (json-object)))
                      (content (json-object-ref message "content" ""))
                      (thought (json-object-ref message "thinking" ""))
                      (chunk-calls
                       (json-array-items
                        (json-object-ref message "tool_calls" (json-array)))))
                 (unless (string-null? thought)
                   (display thought thinking-port)
                   (on-thinking thought))
                 (unless (string-null? content)
                   (display content content-port)
                   (on-content content))
                 (unless (null? chunk-calls)
                   (set! calls
                         (append calls (map parse-ollama-tool-call chunk-calls))))
                 (when (json-object-ref root "done" #f)
                   (set! usage root))))))
          (let* ((content (get-output-string content-port))
                 (thought (get-output-string thinking-port))
                 (assistant
                  (apply
                   json-object
                   (append
                    (list (cons "role" "assistant")
                          (cons "content" content))
                    (if (string-null? thought)
                        '()
                        (list (cons "thinking" thought)))
                    (if (null? calls)
                        '()
                        (list
                         (cons "tool_calls"
                               (tool-calls->ollama-json calls))))))))
            (make-completion content thought calls assistant usage)))
        (parse-ollama-response
         (curl-post-json endpoint api-key payload)))))

(define (provider-complete-openai model base-url api-key messages tool-names)
  (let* ((tool-values (map tool-schema tool-names))
         (base-fields
          (list
           (cons "model" model)
           (cons "messages" (apply json-array messages))))
         (fields
          (if (null? tool-values)
              base-fields
              (append base-fields
                      (list
                       (cons "tools" (apply json-array tool-values))
                       (cons "parallel_tool_calls" #f)))))
         (payload (json-write (apply json-object fields)))
         (endpoint
          (string-append (without-trailing-slash base-url) "/chat/completions")))
    (parse-completion-response
     (curl-post-json endpoint api-key payload))))

(define (provider-complete provider model base-url api-key messages tool-names
                           stream? thinking keep-alive on-content on-thinking)
  (case provider
    ((ollama)
     (provider-complete-ollama
      model base-url api-key messages tool-names stream? thinking keep-alive
      on-content on-thinking))
    ((openai)
     (provider-complete-openai model base-url api-key messages tool-names))
    (else (error "unsupported provider" provider))))
