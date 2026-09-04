(use-modules (srfi srfi-64)
             (live-agent compaction)
             (live-agent json)
             (live-agent provider))

(test-begin "compaction")

(define history
  (list
   (make-message "user" "one")
   (make-message "assistant" "first")
   (make-message "assistant" "calling")
   (make-message "tool" "result")
   (make-message "user" "two")
   (make-message "assistant" "second")
   (make-message "user" "three")
   (make-message "assistant" "third")))

(test-assert "threshold is strict"
  (and (history-needs-compaction? history 7)
       (not (history-needs-compaction? history 8))))

(define compacted (compact-history-with-summary history "First work happened." 5))
(test-equal "summary plus boundary-safe suffix" 5 (length compacted))
(test-equal "summary is a system message"
  "system" (json-object-ref (car compacted) "role"))
(test-equal "suffix starts at the next user boundary"
  "two" (json-object-ref (cadr compacted) "content"))

(test-end "compaction")
