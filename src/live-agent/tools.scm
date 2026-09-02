(define-module (live-agent tools)
  #:use-module (ice-9 format)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 textual-ports)
  #:use-module (live-agent json)
  #:export (execute-tool))

(define max-tool-output (* 64 1024))

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
  (let* ((requested (json-object-ref arguments "path"))
         (root (canonicalize-path working-directory))
         (candidate
          (canonicalize-path
           (if (absolute-file-name? requested)
               requested
               (string-append root "/" requested)))))
    (unless (inside-root? candidate root)
      (error "read path escapes the project root" requested))
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
      (cond
       ((string=? name "read")
        (read-project-file arguments working-directory))
       ((string=? name "shell")
        (run-shell arguments working-directory shell-policy confirm))
       (else (error "tool is not implemented" name))))
    (lambda (key . args)
      (format #f "tool error (~a): ~s" key args))))
