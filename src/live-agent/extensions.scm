(define-module (live-agent extensions)
  #:use-module (ice-9 ftw)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-1)
  #:use-module (live-agent generation)
  #:export (extension-valid-name?
            extension-path
            extension-list
            extension-read
            extension-create!
            extension-export!))

(define (extension-name-character? character)
  (or (char-alphabetic? character)
      (char-numeric? character)
      (char=? character #\-)
      (char=? character #\_)))

(define (extension-valid-name? name)
  (and (string? name)
       (> (string-length name) 0)
       (<= (string-length name) 64)
       (let ((first (string-ref name 0)))
         (or (char-alphabetic? first) (char-numeric? first)))
       (every extension-name-character? (string->list name))))

(define (require-name name)
  (unless (extension-valid-name? name)
    (error "extension name must be 1-64 letters, numbers, hyphens, or underscores"
           name)))

(define (ensure-directory! directory)
  (unless (file-exists? directory)
    (mkdir directory)))

(define (extension-path directory name)
  (require-name name)
  (string-append directory "/" name ".scm"))

(define (extension-list directory)
  (if (not (file-exists? directory))
      '()
      (sort
       (filter-map
        (lambda (entry)
          (and (> (string-length entry) 4)
               (string-suffix? ".scm" entry)
               (let ((name (substring entry 0 (- (string-length entry) 4))))
                 (and (extension-valid-name? name) name))))
        (scandir directory
                 (lambda (entry) (not (member entry '("." ".."))))))
       string<?)))

(define (extension-read directory name)
  (let ((path (extension-path directory name)))
    (unless (file-exists? path)
      (error "extension does not exist" name))
    (call-with-input-file path get-string-all)))

(define (one-line value)
  (string-map
   (lambda (character)
     (if (or (char=? character #\newline) (char=? character #\return))
         #\space
         character))
   value))

(define (write-new! directory name expression description)
  (ensure-directory! directory)
  (let* ((path (extension-path directory name))
         (temporary
          (string-append path "." (number->string (getpid)) ".tmp"))
         (content
          (string-append
           ";; Live Agent extension: " name "\n"
           ";; " (one-line description) "\n\n"
           expression
           (if (string-suffix? "\n" expression) "" "\n"))))
    (when (file-exists? path)
      (error "extension already exists; choose another name" name))
    (validate-live-patch! content)
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (call-with-output-file temporary
          (lambda (port) (display content port)))
        (rename-file temporary path))
      (lambda ()
        (when (file-exists? temporary) (delete-file temporary))))
    path))

(define* (extension-create! directory name expression
                            #:optional (description "Created from a live session."))
  (write-new! directory name expression description))

(define* (extension-export! directory name patches
                            #:optional (description "Exported live generation patches."))
  (when (null? patches)
    (error "the active generation has no live patches to export"))
  (write-new! directory name (string-join patches "\n\n") description))
