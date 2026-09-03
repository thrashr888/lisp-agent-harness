(define-module (live-agent trace)
  #:use-module (ice-9 format)
  #:use-module (ice-9 ftw)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-9)
  #:use-module (live-agent json)
  #:export (tracer?
            make-tracer
            tracer-path
            tracer-session-id
            tracer-session-name
            trace-start!
            trace-end!
            trace-span-id
            trace-tail
            trace-close!))

(define-record-type <tracer>
  (%make-tracer path session-id session-name bridge)
  tracer?
  (path tracer-path)
  (session-id tracer-session-id)
  (session-name tracer-session-name)
  (bridge tracer-bridge set-tracer-bridge!))

(define-record-type <trace-span>
  (%make-trace-span tracer trace-id span-id parent-id name kind
                    start-ns start-ticks attributes ended?)
  trace-span?
  (tracer trace-span-tracer)
  (trace-id trace-span-trace-id)
  (span-id trace-span-id)
  (parent-id trace-span-parent-id)
  (name trace-span-name)
  (kind trace-span-kind)
  (start-ns trace-span-start-ns)
  (start-ticks trace-span-start-ticks)
  (attributes trace-span-attributes)
  (ended? trace-span-ended? set-trace-span-ended?!))

(define id-counter 0)

(define (wall-time-ns)
  (let ((value (gettimeofday)))
    (+ (* (car value) 1000000000) (* (cdr value) 1000))))

(define (fresh-hex width)
  (set! id-counter (+ id-counter 1))
  (let* ((now (gettimeofday))
         (seed (+ (* (car now) 1000003)
                  (cdr now)
                  (* (getpid) 7919)
                  id-counter)))
    (let loop ((remaining width) (value seed) (parts '()))
      (if (= remaining 0)
          (string-concatenate-reverse parts)
          (let* ((chunk-width (min 8 remaining))
                 (chunk (modulo value (expt 16 chunk-width))))
            (loop (- remaining chunk-width)
                  (+ (quotient value 17) (* id-counter 104729))
                  (cons (format #f "~v,'0x" chunk-width chunk) parts)))))))

(define (attribute-key value)
  (if (symbol? value) (symbol->string value) value))

(define (bounded value)
  (if (and (string? value) (> (string-length value) 4096))
      (string-append (substring value 0 4096)
                     "\n…[trace attribute truncated; original chars="
                     (number->string (string-length value)) "]")
      value))

(define (attributes->json attributes)
  (apply
   json-object
   (map (lambda (entry)
          (cons (attribute-key (car entry)) (bounded (cdr entry))))
        attributes)))

(define (open-otel-bridge endpoint)
  (let* ((root (getenv "LISP_AGENT_PROJECT_ROOT"))
         (script (and root (string-append root "/scripts/otel-bridge.py"))))
    (if (and endpoint script (file-exists? script))
        (begin
          ;; An optional exporter must never take down the local harness when
          ;; its collector or dependency runner exits early.
          (sigaction SIGPIPE SIG_IGN)
          (open-pipe* OPEN_WRITE
                      "uv" "run" "--quiet" "--script" script
                      "--endpoint" endpoint
                      "--project" "lisp-agent-harness"))
        #f)))

(define* (make-tracer state-directory
                      #:optional
                      (endpoint (or (getenv "LISP_AGENT_OTEL_ENDPOINT")
                                    (getenv "PHOENIX_COLLECTOR_ENDPOINT")))
                      (session-id #f)
                      (session-name #f))
  (let ((path (string-append state-directory "/traces.jsonl")))
    (%make-tracer path (or session-id (fresh-hex 32)) session-name
                  (open-otel-bridge endpoint))))

(define* (trace-start! tracer name kind attributes #:optional parent)
  (%make-trace-span
   tracer
   (if parent (trace-span-trace-id parent) (fresh-hex 32))
   (fresh-hex 16)
   (and parent (trace-span-id parent))
   name
   kind
   (wall-time-ns)
   (get-internal-real-time)
   (append
    `((openinference.span.kind . ,kind)
      (session.id . ,(tracer-session-id tracer)))
    (if (tracer-session-name tracer)
        `((session.name . ,(tracer-session-name tracer)))
        '())
    attributes)
   #f))

(define (write-span! span end-ns duration-ms status attributes)
  (let* ((tracer (trace-span-tracer span))
         (value
          (json-object
           (cons "trace_id" (trace-span-trace-id span))
           (cons "span_id" (trace-span-id span))
           (cons "parent_span_id"
                 (or (trace-span-parent-id span) json-null))
           (cons "name" (trace-span-name span))
           (cons "kind" (trace-span-kind span))
           (cons "start_time_unix_nano" (trace-span-start-ns span))
           (cons "end_time_unix_nano" end-ns)
           (cons "duration_ms" duration-ms)
           (cons "status" status)
           (cons "attributes"
                 (attributes->json
                  (append (trace-span-attributes span) attributes)))))
         (line (json-write value)))
    (let ((port (open-file (tracer-path tracer) "a")))
      (dynamic-wind
        (lambda () #t)
        (lambda ()
        (display line port)
        (newline port)
          (force-output port))
        (lambda () (close-port port))))
    (let ((bridge (tracer-bridge tracer)))
      (when bridge
        (catch #t
          (lambda ()
            (display line bridge)
            (newline bridge)
            (force-output bridge))
          (lambda _
            (catch #t
              (lambda () (close-pipe bridge))
              (lambda _ #f))
            (set-tracer-bridge! tracer #f)))))))

(define* (trace-end! span #:optional (status "OK") (attributes '()))
  (unless (trace-span-ended? span)
    (let* ((end-ns (wall-time-ns))
           (elapsed (- (get-internal-real-time)
                       (trace-span-start-ticks span)))
           (duration-ms
            (/ (round (* 1000.0 (/ elapsed internal-time-units-per-second)))
               1.0)))
      (write-span! span end-ns duration-ms status attributes)
      (set-trace-span-ended?! span #t))))

(define (trace-tail tracer count)
  (if (not (file-exists? (tracer-path tracer)))
      '()
      (call-with-input-file
          (tracer-path tracer)
        (lambda (port)
          (let loop ((lines '()))
            (let ((line (get-line port)))
              (if (eof-object? line)
                  (reverse lines)
                  (loop
                   (let ((next (cons line lines)))
                     (if (> (length next) count)
                         (reverse (cdr (reverse next)))
                         next))))))))))

(define (trace-close! tracer)
  (let ((bridge (tracer-bridge tracer)))
    (when bridge
      (catch #t
        (lambda () (close-pipe bridge))
        (lambda _ #f))
      (set-tracer-bridge! tracer #f))))
