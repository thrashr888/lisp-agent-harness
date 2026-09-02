(define-module (live-agent generation)
  #:use-module (ice-9 exceptions)
  #:use-module (ice-9 format)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:export (generation?
            generation-id
            generation-module
            generation-source-path
            generation-source-text
            generation-patches
            generation-fingerprint
            generation-loaded-at
            build-generation
            generation-ref
            generation-call
            read-source-file))

(define required-bindings
  '(agent-name
    agent-provider
    agent-model
    agent-base-url
    agent-api-key-environment
    agent-stream?
    agent-thinking
    agent-max-tool-rounds
    agent-system-prompt
    agent-tools
    agent-shell-policy
    agent-transform-user
    agent-demo-response))

;; The live image receives language and data primitives, not Guile's process,
;; filesystem, networking, module-resolution, dynamic-loading, or eval APIs.
;; Authority-bearing work must cross a stable tool boundary.
(define safe-bindings
  '(define define* define-values define-syntax syntax-rules
    lambda quote quasiquote unquote unquote-splicing begin
    if cond case and or when unless let let* letrec letrec* set!
    values call-with-values apply
    boolean? not eq? eqv? equal?
    number? integer? exact? inexact? zero? positive? negative?
    + - * / = < > <= >= max min abs modulo remainder quotient
    string? string string-length string-ref substring
    string-append string=? string-ci=? string-upcase string-downcase
    string-trim string-trim-right string-trim-both
    symbol? symbol->string string->symbol keyword?
    char? char=? char-ci=? char-alphabetic? char-numeric? char-whitespace?
    pair? null? list? list cons car cdr caar cadr cdar cddr
    length append reverse list-ref list-tail member memq memv assq assoc
    map for-each filter
    vector? vector make-vector vector-length vector-ref vector-set!
    error format object->string))

(define-record-type <generation>
  (make-generation id module source-path source-text patches fingerprint loaded-at)
  generation?
  (id generation-id)
  (module generation-module)
  (source-path generation-source-path)
  (source-text generation-source-text)
  (patches generation-patches)
  (fingerprint generation-fingerprint)
  (loaded-at generation-loaded-at))

(define (read-source-file path)
  (call-with-input-file path get-string-all))

(define (timestamp)
  (strftime "%Y-%m-%dT%H:%M:%SZ" (gmtime (current-time))))

;; Stable, deterministic FNV-1a identifier. This is a change identifier, not a
;; cryptographic signature. A signed provenance layer belongs below this spike.
(define (fingerprint-text text)
  (let loop ((chars (string->list text))
             (hash #xcbf29ce484222325))
    (if (null? chars)
        (format #f "~16,'0x" hash)
        (loop (cdr chars)
              (modulo (* (logxor hash (char->integer (car chars)))
                         #x100000001b3)
                      #x10000000000000000)))))

(define (fresh-module)
  (let ((module (make-module)))
    (module-use!
     module
     (resolve-interface '(guile) #:select safe-bindings))
    module))

(define (eval-all! text module)
  (call-with-input-string
      text
    (lambda (port)
      (let loop ()
        (let ((form (read port)))
          (unless (eof-object? form)
            (eval form module)
            (loop)))))))

(define (validate-module! module)
  (for-each
   (lambda (name)
     (unless (module-variable module name)
       (error "agent image is missing required binding" name)))
   required-bindings)
  (let ((policy (module-ref module 'agent-shell-policy)))
    (unless (memq policy '(deny ask))
      (error "agent-shell-policy must be deny or ask" policy)))
  (let ((provider (module-ref module 'agent-provider))
        (model (module-ref module 'agent-model))
        (base-url (module-ref module 'agent-base-url))
        (key-environment
         (module-ref module 'agent-api-key-environment))
        (stream? (module-ref module 'agent-stream?))
        (thinking (module-ref module 'agent-thinking))
        (tools (module-ref module 'agent-tools)))
    (unless (memq provider '(ollama openai))
      (error "agent-provider must be ollama or openai" provider))
    (unless (and (string? model) (not (string-null? model)))
      (error "agent-model must be a non-empty string" model))
    (unless (and (string? base-url) (not (string-null? base-url)))
      (error "agent-base-url must be a non-empty string" base-url))
    (unless (or (not key-environment) (string? key-environment))
      (error "agent-api-key-environment must be a string or #f"
             key-environment))
    (unless (boolean? stream?)
      (error "agent-stream? must be a boolean" stream?))
    (unless (or (boolean? thinking)
                (memq thinking '(low medium high)))
      (error "agent-thinking must be #t, #f, low, medium, or high" thinking))
    (unless (and (list? tools)
                 (every (lambda (tool) (memq tool '(read shell live_eval))) tools))
      (error "agent-tools may contain only read, shell, and live_eval" tools)))
  (let ((rounds (module-ref module 'agent-max-tool-rounds)))
    (unless (and (integer? rounds) (>= rounds 0) (<= rounds 8))
      (error "agent-max-tool-rounds must be an integer from 0 through 8" rounds)))
  #t)

(define (build-generation id source-path source-text patches)
  (let ((module (fresh-module)))
    (eval-all! source-text module)
    (for-each (lambda (patch) (eval-all! patch module)) patches)
    (validate-module! module)
    (make-generation
     id
     module
     source-path
     source-text
     patches
     (fingerprint-text
      (string-append source-text "\n" (string-join patches "\n")))
     (timestamp))))

(define (generation-ref generation name)
  (module-ref (generation-module generation) name))

(define (generation-call generation name . args)
  (apply (generation-ref generation name) args))
