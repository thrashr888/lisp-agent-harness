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
            completion-tool-calls
            completion-assistant-message
            make-message
            make-tool-result-message
            parse-completion-response
            provider-complete))

(define-record-type <tool-call>
  (make-tool-call id name arguments raw-arguments)
  tool-call?
  (id tool-call-id)
  (name tool-call-name)
  (arguments tool-call-arguments)
  (raw-arguments tool-call-raw-arguments))

(define-record-type <completion>
  (make-completion content tool-calls assistant-message)
  completion?
  (content completion-content)
  (tool-calls completion-tool-calls)
  (assistant-message completion-assistant-message))

(define (make-message role content)
  (json-object (cons "role" role) (cons "content" content)))

(define (make-tool-result-message call-id content)
  (json-object
   (cons "role" "tool")
   (cons "tool_call_id" call-id)
   (cons "content" content)))

(define (tool-schema name)
  (cond
   ((string=? name "read")
    (json-object
     (cons "type" "function")
     (cons "function"
           (json-object
            (cons "name" "read")
            (cons "description" "Read a UTF-8 text file inside the current project")
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
   ((string=? name "shell")
    (json-object
     (cons "type" "function")
     (cons "function"
           (json-object
            (cons "name" "shell")
            (cons "description" "Run a shell command after explicit user approval")
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
        (make-completion content calls assistant)))))

(define (provider-complete model base-url api-key messages tool-names)
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
