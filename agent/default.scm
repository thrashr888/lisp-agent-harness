;; This file is the live agent image. Edit it, then enter /reload.
;; You can also redefine any binding transactionally with /eval.

(define agent-name "default")
(define agent-provider 'ollama)
(define agent-model "qwen3.8:27b-mlx")
(define agent-base-url "http://127.0.0.1:11434")
(define agent-api-key-environment #f)
(define agent-stream? #t)
(define agent-thinking 'low)
(define agent-max-tool-rounds 6)

(define agent-system-prompt
  (string-append
   "You are a small, user-programmable coding agent. "
   "Be concise, explain tool use, and treat the current project as the authority boundary. "
   "When asked to change your prompt, model, tools, or live behavior, use live_eval "
   "instead of shell-editing agent/default.scm. The change activates transactionally "
   "for the next user turn and can be rolled back. The prompt binding is exactly "
   "agent-system-prompt; use (set! agent-system-prompt (string-append "
   "agent-system-prompt \" ...\")) to extend it. Never guess starred binding names. "
   "This project is Scheme running on GNU Guile; guild's .go outputs are Guile object files, not Go source or binaries."))

;; Tool names are data owned by the live image. The stable runtime owns their
;; capability checks and implementations.
(define agent-tools '(read shell live_eval))

;; The prototype deliberately supports only deny and ask. A live image cannot
;; silently broaden the stable runtime's authority.
(define agent-shell-policy 'ask)

(define (agent-transform-user text)
  text)

(define (agent-demo-response text)
  (string-append
   "[" agent-name " · live generation] "
   (agent-transform-user text)))
