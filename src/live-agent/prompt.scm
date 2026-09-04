(define-module (live-agent prompt)
  #:use-module (srfi srfi-1)
  #:export (build-provider-messages
            persist-provider-turn
            prompt-cache-prefix-count))

;; Keep the reusable prefix ahead of per-turn retrieved context. Ollama's
;; prefix cache can then reuse the system prompt and all history that predates
;; the newest turn, even when context selection changes between turns.
(define (build-provider-messages system history turn-context user)
  (append (list system) history turn-context (list user)))

(define (prompt-cache-prefix-count history)
  (+ 1 (length history)))

;; Provider messages contain one runtime-owned system message and zero or more
;; ephemeral context messages. Persist only the prior history plus this turn's
;; user/assistant/tool tail.
(define (persist-provider-turn history context-count completed-messages)
  (let ((owned-prefix-count
         (+ (prompt-cache-prefix-count history) context-count)))
    (when (< (length completed-messages) owned-prefix-count)
      (error "completed provider messages are shorter than their owned prefix"
             (length completed-messages) owned-prefix-count))
    (append history (drop completed-messages owned-prefix-count))))
