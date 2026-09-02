;; This file is the live agent image. Edit it, then enter /reload.
;; You can also redefine any binding transactionally with /eval.

(define agent-name "default")
(define agent-model "qwen3.8:27b-mlx")
(define agent-base-url "http://127.0.0.1:11434/v1")
(define agent-api-key-environment #f)
(define agent-max-tool-rounds 6)

(define agent-system-prompt
  (string-append
   "You are a small, user-programmable coding agent. "
   "Be concise, explain tool use, and treat the current project as the authority boundary."))

;; Tool names are data owned by the live image. The stable runtime owns their
;; capability checks and implementations.
(define agent-tools '(read shell))

;; The prototype deliberately supports only deny and ask. A live image cannot
;; silently broaden the stable runtime's authority.
(define agent-shell-policy 'ask)

(define (agent-transform-user text)
  text)

(define (agent-demo-response text)
  (string-append
   "[" agent-name " · live generation] "
   (agent-transform-user text)))
