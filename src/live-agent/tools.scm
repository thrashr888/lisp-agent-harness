(define-module (live-agent tools)
  #:use-module (ice-9 format)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-9)
  #:use-module (live-agent json)
  #:export (make-tool-result
            tool-result?
            tool-result-success?
            tool-result-output
            execute-tool))

(define-record-type <tool-result>
  (make-tool-result success? output)
  tool-result?
  (success? tool-result-success?)
  (output tool-result-output))

(define max-tool-output (* 64 1024))
(define max-write-input (* 256 1024))
(define max-edit-input (* 512 1024))

(define (bounded value)
  (if (> (string-length value) max-tool-output)
      (string-append
       (substring value 0 max-tool-output)
       "\n…[tool output truncated; original chars="
       (number->string (string-length value))
       "]")
      value))

(define (inside-root? path root)
  (or (string=? path root)
      (string-prefix? (string-append root "/") path)))

(define (require-string arguments key)
  (let ((value (json-object-ref arguments key #f)))
    (unless (string? value)
      (error "tool argument must be a string" key))
    value))

(define (resolve-existing-path requested working-directory label)
  (unless (and (string? requested) (not (string-null? requested)))
    (error "path must be a non-empty string" requested))
  (let* ((root (canonicalize-path working-directory))
         (candidate
          (canonicalize-path
           (if (absolute-file-name? requested)
               requested
               (string-append root "/" requested)))))
    (unless (inside-root? candidate root)
      (error (string-append label " path escapes the project root") requested))
    (list root candidate)))

(define (resolve-write-path requested working-directory)
  (unless (and (string? requested) (not (string-null? requested)))
    (error "path must be a non-empty string" requested))
  (let* ((root (canonicalize-path working-directory))
         (unresolved
          (if (absolute-file-name? requested)
              requested
              (string-append root "/" requested)))
         (leaf (basename unresolved))
         (parent (canonicalize-path (dirname unresolved)))
         (candidate (string-append parent "/" leaf)))
    (unless (inside-root? parent root)
      (error "write path escapes the project root" requested))
    (when (member leaf '("" "." ".."))
      (error "write path must name a file" requested))
    (when (and (file-exists? candidate)
               (not (inside-root? (canonicalize-path candidate) root)))
      (error "write path escapes the project root" requested))
    (list root candidate)))

(define (shell-quote value)
  (call-with-output-string
   (lambda (port)
     (write-char #\' port)
     (string-for-each
      (lambda (character)
        (if (char=? character #\')
            (display "'\\''" port)
            (write-char character port)))
      value)
     (write-char #\' port))))

(define (read-project-file arguments working-directory)
  (let* ((requested (require-string arguments "path"))
         (resolved (resolve-existing-path requested working-directory "read"))
         (candidate (cadr resolved)))
    (let* ((size (stat:size (stat candidate)))
           (content
            (call-with-input-file
                candidate
              (lambda (port)
                (let ((value (get-string-n port max-tool-output)))
                  (if (eof-object? value) "" value))))))
      (if (> size max-tool-output)
          (string-append
           content
           "\n…[file truncated; bytes=" (number->string size) "]")
          content))))

(define (atomic-write-file path content)
  (let ((temporary
         (string-append (dirname path) "/.lisp-agent-write-"
                        (number->string (getpid)) "-XXXXXX")))
    (let* ((port (mkstemp temporary))
           (actual (port-filename port)))
      (dynamic-wind
        (lambda () #t)
        (lambda ()
          (display content port)
          (force-output port)
          (close-port port)
          (rename-file actual path))
        (lambda ()
          (unless (port-closed? port) (close-port port))
          (when (file-exists? actual) (delete-file actual)))))))

(define (write-project-file arguments working-directory)
  (let* ((requested (require-string arguments "path"))
         (content (require-string arguments "content"))
         (resolved (resolve-write-path requested working-directory))
         (candidate (cadr resolved)))
    (when (> (string-length content) max-write-input)
      (error "write content exceeds the 256 KiB limit" (string-length content)))
    (when (and (file-exists? candidate)
               (eq? 'directory (stat:type (stat candidate))))
      (error "write path is a directory" requested))
    (atomic-write-file candidate content)
    (format #f "wrote ~a chars to ~a" (string-length content) requested)))

(define (occurrence-count text fragment)
  (let loop ((start 0) (count 0))
    (let ((index (string-contains text fragment start)))
      (if index
          (loop (+ index (string-length fragment)) (+ count 1))
          count))))

(define (replace-occurrences text old-text new-text)
  (let ((port (open-output-string)))
    (let loop ((start 0))
      (let ((index (string-contains text old-text start)))
        (if index
            (begin
              (display (substring text start index) port)
              (display new-text port)
              (loop (+ index (string-length old-text))))
            (display (substring text start) port))))
    (get-output-string port)))

(define (edit-project-file arguments working-directory)
  (let* ((requested (require-string arguments "path"))
         (old-text (require-string arguments "old_text"))
         (new-text (require-string arguments "new_text"))
         (replace-all? (json-object-ref arguments "replace_all" #f))
         (resolved (resolve-existing-path requested working-directory "edit"))
         (candidate (cadr resolved))
         (size (stat:size (stat candidate))))
    (when (string-null? old-text)
      (error "old_text cannot be empty"))
    (when (> size max-edit-input)
      (error "edit file exceeds the 512 KiB limit" size))
    (let* ((content (call-with-input-file candidate get-string-all))
           (count (occurrence-count content old-text)))
      (when (= count 0)
        (error "old_text was not found" requested))
      (when (and (> count 1) (not replace-all?))
        (error "old_text is ambiguous; set replace_all to true" count))
      (let ((updated (replace-occurrences content old-text new-text)))
        (when (> (string-length updated) max-write-input)
          (error "edited content exceeds the 256 KiB write limit"
                 (string-length updated)))
        (atomic-write-file candidate updated)
        (format #f "edited ~a occurrence~a in ~a"
                count (if (= count 1) "" "s") requested)))))

(define (run-rg arguments working-directory)
  (let* ((query (require-string arguments "query"))
         (requested (json-object-ref arguments "path" "."))
         (glob (json-object-ref arguments "glob" #f))
         (regex? (json-object-ref arguments "regex" #f)))
    (when (string-null? query) (error "rg query cannot be empty"))
    (unless (string? requested) (error "rg path must be a string"))
    (unless (or (not glob) (string? glob))
      (error "rg glob must be a string"))
    (unless (boolean? regex?)
      (error "rg regex must be a boolean"))
    (let* ((resolved (resolve-existing-path requested working-directory "rg"))
           (root (car resolved))
           (candidate (cadr resolved))
           (arguments
            (append
             '("--line-number" "--color=never" "--no-heading"
               "--max-count" "200" "--max-filesize" "1M")
             (if regex? '() '("--fixed-strings"))
             (if glob (list "--glob" glob) '())
             (list "--" query candidate)))
           (error-template
            (string-append "/tmp/lisp-agent-rg-error-"
                           (number->string (getpid)) "-XXXXXX"))
           (error-port (mkstemp error-template))
           (error-path (port-filename error-port))
           (result
            (dynamic-wind
              (lambda () #t)
              (lambda ()
                (let* ((port
                        (with-error-to-port
                         error-port
                         (lambda ()
                           (apply open-pipe* OPEN_READ "rg" arguments))))
                       (output (get-string-all port))
                       (status (close-pipe port)))
                  (force-output error-port)
                  (seek error-port 0 SEEK_SET)
                  (list output (get-string-all error-port)
                        (status:exit-val status))))
              (lambda ()
                (unless (port-closed? error-port) (close-port error-port))
                (when (file-exists? error-path) (delete-file error-path)))))
           (output (car result))
           (error-output (cadr result))
           (exit-code (caddr result)))
      (cond
       ((= exit-code 0)
        (bounded
         (replace-occurrences output (string-append root "/") "")))
       ((= exit-code 1) "No matches.")
       (else
        (error
         (if regex?
             "rg regular expression is invalid or rg failed"
             "rg failed")
         exit-code
         (bounded
          (if (string-null? error-output) output error-output))))))))

(define (run-shell arguments working-directory policy confirm)
  (let ((command (json-object-ref arguments "command")))
    (when (eq? policy 'deny)
      (error "shell capability is denied by the live image"))
    (unless (and (eq? policy 'ask) (confirm command))
      (error "shell command was not approved"))
    (let* ((wrapped
            (string-append "cd "
                           (shell-quote working-directory)
                           " && " command " 2>&1"))
           (port (open-pipe* OPEN_READ "/bin/zsh" "-lc" wrapped))
           (output (get-string-all port))
           (status (close-pipe port))
           (exit-code (status:exit-val status)))
      (format #f "exit=~a~%~a" exit-code (bounded output)))))

(define (execute-tool name arguments working-directory shell-policy confirm)
  (catch #t
    (lambda ()
      (make-tool-result
       #t
       (cond
        ((string=? name "read")
         (read-project-file arguments working-directory))
        ((string=? name "rg")
         (run-rg arguments working-directory))
        ((string=? name "write")
         (write-project-file arguments working-directory))
        ((string=? name "edit")
         (edit-project-file arguments working-directory))
        ((string=? name "shell")
         (run-shell arguments working-directory shell-policy confirm))
        (else (error "tool is not implemented" name)))))
    (lambda (key . args)
      (make-tool-result #f (format #f "tool error (~a): ~s" key args)))))
