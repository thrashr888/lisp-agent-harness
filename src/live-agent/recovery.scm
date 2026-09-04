(define-module (live-agent recovery)
  #:use-module (ice-9 ftw)
  #:use-module (ice-9 textual-ports)
  #:use-module (live-agent json)
  #:export (recovery-path
            recovery-read
            recovery-write!
            recovery-clear!))

(define max-recovery-bytes (* 768 1024))

(define (recovery-path state-directory)
  (string-append state-directory "/interrupted-tool.json"))

(define (atomic-write! path content)
  (when (> (string-length content) max-recovery-bytes)
    (error "interrupted tool record exceeds the 768 KiB limit"))
  (let* ((template
          (string-append (dirname path) "/.recovery-"
                         (number->string (getpid)) "-XXXXXX"))
         (port (mkstemp template))
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
        (when (file-exists? actual) (delete-file actual))))))

(define (timestamp)
  (strftime "%Y-%m-%dT%H:%M:%SZ" (gmtime (current-time))))

(define (recovery-write! state-directory tool arguments generation-id)
  (unless (and (string? tool) (json-object? arguments))
    (error "invalid interrupted tool record" tool))
  (let ((value
         (json-object
          (cons "version" 1)
          (cons "state" "execution-started")
          (cons "tool" tool)
          (cons "arguments" arguments)
          (cons "generation_id" generation-id)
          (cons "created_at" (timestamp)))))
    (atomic-write!
     (recovery-path state-directory)
     (string-append (json-write value) "\n"))
    value))

(define (recovery-read state-directory)
  (let ((path (recovery-path state-directory)))
    (if (not (file-exists? path))
        #f
        (begin
          (when (> (stat:size (stat path)) max-recovery-bytes)
            (error "interrupted tool record exceeds the 768 KiB limit" path))
          (let ((value
                 (call-with-input-file
                     path
                   (lambda (port) (json-read (get-string-all port))))))
            (unless (and (json-object? value)
                         (equal? (json-object-ref value "version" #f) 1)
                         (string? (json-object-ref value "tool" #f))
                         (json-object? (json-object-ref value "arguments" #f)))
              (error "invalid interrupted tool record" path))
            value)))))

(define (recovery-clear! state-directory)
  (let ((path (recovery-path state-directory)))
    (when (file-exists? path) (delete-file path))))
