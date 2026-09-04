(use-modules (srfi srfi-1)
             (srfi srfi-64)
             (live-agent json)
             (live-agent prompt)
             (live-agent provider))

(test-begin "prompt")

(define system (make-message "system" "stable rules"))
(define old-user (make-message "user" "old question"))
(define old-assistant (make-message "assistant" "old answer"))
(define history (list old-user old-assistant))
(define context-a (make-message "system" "retrieved A"))
(define context-b (make-message "system" "retrieved B"))
(define user (make-message "user" "new question"))

(define request-a
  (build-provider-messages system history (list context-a) user))
(define request-b
  (build-provider-messages system history (list context-b) user))

(test-equal "system and history form the reusable prefix"
  (take request-a (prompt-cache-prefix-count history))
  (take request-b (prompt-cache-prefix-count history)))
(test-equal "retrieved context follows stable history"
  "retrieved A"
  (json-object-ref (list-ref request-a 3) "content"))

(define assistant (make-message "assistant" "new answer"))
(define completed (append request-a (list assistant)))
(define persisted (persist-provider-turn history 1 completed))

(test-equal "ephemeral system and context are not persisted"
  (list old-user old-assistant user assistant)
  persisted)

(test-end "prompt")
