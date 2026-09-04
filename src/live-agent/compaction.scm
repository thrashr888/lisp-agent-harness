(define-module (live-agent compaction)
  #:use-module (srfi srfi-1)
  #:use-module (live-agent json)
  #:use-module (live-agent provider)
  #:export (history-needs-compaction?
            compaction-prefix
            compaction-suffix
            compact-history-with-summary))

(define (history-needs-compaction? history threshold)
  (> (length history) threshold))

;; Keep a conversation boundary intact.  Starting the retained suffix at a
;; user message avoids orphaning an assistant tool call or tool result.
(define (split-at-user-boundary history keep-recent)
  (let* ((length* (length history))
         (initial (max 0 (- length* keep-recent))))
    (let loop ((index initial))
      (cond
       ((>= index length*) length*)
       ((string=? (json-object-ref (list-ref history index) "role" "") "user")
        index)
       (else (loop (+ index 1)))))))

(define (compaction-prefix history keep-recent)
  (take history (split-at-user-boundary history keep-recent)))

(define (compaction-suffix history keep-recent)
  (drop history (split-at-user-boundary history keep-recent)))

(define (compact-history-with-summary history summary keep-recent)
  (let ((prefix (compaction-prefix history keep-recent)))
    (if (null? prefix)
        history
        (cons
         (make-message
          "system"
          (string-append
           "Earlier session summary (compacted; source messages are preserved in the durable trace):\n"
           summary))
         (compaction-suffix history keep-recent)))))
