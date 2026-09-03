(define-module (live-agent runtime)
  #:use-module (ice-9 exceptions)
  #:use-module (ice-9 ftw)
  #:use-module (ice-9 threads)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-9)
  #:use-module (live-agent generation)
  #:export (runtime?
            make-runtime
            runtime-current
            runtime-past
            runtime-journal-path
            runtime-reload!
            runtime-reload-if-changed!
            runtime-validate-patch!
            runtime-apply-patch!
            runtime-remove-patch!
            runtime-eval!
            runtime-rollback!
            runtime-record!
            runtime-generation-summaries))

(define-record-type <runtime>
  (%make-runtime current past next-id journal-path lock)
  runtime?
  (current runtime-current set-runtime-current!)
  (past runtime-past set-runtime-past!)
  (next-id runtime-next-id set-runtime-next-id!)
  (journal-path runtime-journal-path)
  (lock runtime-lock))

(define (timestamp)
  (strftime "%Y-%m-%dT%H:%M:%SZ" (gmtime (current-time))))

(define (ensure-directory! path)
  (unless (file-exists? path)
    (let ((parent (dirname path)))
      (unless (or (string=? parent path)
                  (string=? parent ".")
                  (file-exists? parent))
        (ensure-directory! parent)))
    (mkdir path)))

(define (bounded-string value)
  (if (and (string? value) (> (string-length value) 4096))
      (string-append (substring value 0 4096)
                     "\n…[journal value truncated; original chars="
                     (number->string (string-length value))
                     "]")
      value))

(define (runtime-record! runtime kind fields)
  (with-mutex (runtime-lock runtime)
    (let ((event
           `((timestamp . ,(timestamp))
             (kind . ,kind)
             ,@(map (lambda (pair)
                      (cons (car pair) (bounded-string (cdr pair))))
                    fields))))
      (let ((port (open-file (runtime-journal-path runtime) "a")))
        (dynamic-wind
          (lambda () #t)
          (lambda ()
            (write event port)
            (newline port)
            (force-output port))
          (lambda () (close-port port)))))))

(define (activate! runtime generation reason extra-fields)
  (let ((old (runtime-current runtime)))
    (when old
      (set-runtime-past! runtime (cons old (runtime-past runtime))))
    (set-runtime-current! runtime generation)
    (set-runtime-next-id! runtime (+ 1 (generation-id generation)))
    (runtime-record!
     runtime
     'generation-activated
     `((generation . ,(generation-id generation))
       (reason . ,reason)
       (fingerprint . ,(generation-fingerprint generation))
       (patch-count . ,(length (generation-patches generation)))
       ,@extra-fields))
    generation))

(define max-live-patches 64)

(define (remove-first value items)
  (cond
   ((null? items) '())
   ((equal? value (car items)) (cdr items))
   (else (cons (car items) (remove-first value (cdr items))))))

(define (make-runtime source-path state-directory)
  (ensure-directory! state-directory)
  (let* ((journal-path (string-append state-directory "/events.scm-log"))
         (source-text (read-source-file source-path))
         (generation (build-generation 1 source-path source-text '()))
         ;; Reloads may arrive from a watcher while a model turn is using a
         ;; pinned generation. Serialize transitions and journal appends; the
         ;; recursive flavor permits activate! to record inside a transition.
         (runtime
          (%make-runtime generation '() 2 journal-path
                         (make-recursive-mutex))))
    (runtime-record!
     runtime
     'runtime-started
     `((generation . 1)
       (source . ,source-path)
       (fingerprint . ,(generation-fingerprint generation))))
    runtime))

(define* (runtime-reload! runtime #:optional (keep-patches? #t))
  (with-mutex (runtime-lock runtime)
    (let* ((current (runtime-current runtime))
           (source-path (generation-source-path current))
           (source-text (read-source-file source-path))
           (patches (if keep-patches? (generation-patches current) '()))
           (generation
            (build-generation
             (runtime-next-id runtime) source-path source-text patches)))
      (activate! runtime generation
                 (if keep-patches? 'reload 'reload-clean)
                 `((source . ,source-path))))))

(define (runtime-reload-if-changed! runtime)
  (with-mutex (runtime-lock runtime)
    (let* ((current (runtime-current runtime))
           (source-path (generation-source-path current))
           (source-text (read-source-file source-path)))
      (if (string=? source-text (generation-source-text current))
          #f
          (let ((generation
                 (build-generation
                  (runtime-next-id runtime)
                  source-path
                  source-text
                  (generation-patches current))))
            (activate! runtime generation 'auto-reload
                       `((source . ,source-path))))))))

(define (runtime-validate-patch! runtime expression)
  (with-mutex (runtime-lock runtime)
    (validate-live-patch! expression)
    (let* ((current (runtime-current runtime))
           (patches (append (generation-patches current) (list expression))))
      (when (> (length patches) max-live-patches)
        (error "live patch limit reached" max-live-patches))
      (build-generation
       (runtime-next-id runtime)
       (generation-source-path current)
       (generation-source-text current)
       patches))))

(define* (runtime-apply-patch! runtime expression reason
                               #:optional (extra-fields '()))
  (with-mutex (runtime-lock runtime)
    (let ((generation (runtime-validate-patch! runtime expression)))
      (activate! runtime generation reason
                 `((expression . ,expression) ,@extra-fields)))))

(define* (runtime-remove-patch! runtime expression reason
                                #:optional (extra-fields '()))
  (with-mutex (runtime-lock runtime)
    (let* ((current (runtime-current runtime))
           (current-patches (generation-patches current)))
      (unless (member expression current-patches)
        (error "live patch is not active"))
      (let* ((patches (remove-first expression current-patches))
             (generation
              (build-generation
               (runtime-next-id runtime)
               (generation-source-path current)
               (generation-source-text current)
               patches)))
        (activate! runtime generation reason
                   `((expression . ,expression) ,@extra-fields))))))

(define (runtime-eval! runtime expression)
  (runtime-apply-patch! runtime expression 'eval))

(define (runtime-rollback! runtime)
  (with-mutex (runtime-lock runtime)
    (if (null? (runtime-past runtime))
        #f
        (let* ((from (runtime-current runtime))
               (target (car (runtime-past runtime))))
          (set-runtime-current! runtime target)
          (set-runtime-past! runtime (cdr (runtime-past runtime)))
          (runtime-record!
           runtime
           'generation-rolled-back
           `((from . ,(generation-id from))
             (to . ,(generation-id target))
             (fingerprint . ,(generation-fingerprint target))))
          target))))

(define (runtime-generation-summaries runtime)
  (with-mutex (runtime-lock runtime)
    (map
     (lambda (generation)
       `((id . ,(generation-id generation))
         (fingerprint . ,(generation-fingerprint generation))
         (patches . ,(length (generation-patches generation)))
         (loaded-at . ,(generation-loaded-at generation))))
     (cons (runtime-current runtime) (runtime-past runtime)))))
