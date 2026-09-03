;; This file is the live agent image. Edit it, then enter /reload.
;; You can also redefine any binding transactionally with /eval.

(define agent-name "default")
(define agent-provider 'ollama)
(define agent-model "qwen3.8:27b-mlx")
(define agent-base-url "http://127.0.0.1:11434")
(define agent-api-key-environment #f)
(define agent-stream? #t)
(define agent-thinking #f)
(define agent-max-tool-rounds 6)

(define agent-system-prompt
  (string-append
   "You are a small, user-programmable coding agent. "
   "Be concise, explain tool use, and treat the current project as the authority boundary. "
   "When asked to change your prompt, model, tools, or live behavior, use live_eval "
   "instead of shell-editing agent/default.scm. The change activates transactionally "
   "for the next user turn and can be rolled back. Before calling live_eval, explain "
   "the exact binding change, why it is needed, and the expected next-turn behavior. "
   "After it returns, explain the reported before/after generations and fingerprints. "
   "The prompt binding is exactly "
   "agent-system-prompt; use (set! agent-system-prompt (string-append "
   "agent-system-prompt \" ...\")) to extend it. Never guess starred binding names. "
   "Prefer read for known files and rg for project search. Use edit for exact changes "
   "and write for complete new file content. Use one most-likely path at a time instead "
   "of guessing several paths in parallel. Use shell only when the narrower tools "
   "cannot perform the task. In this Scheme project, an import means #:use-module or "
   "(use-modules unless the user names another language; search those literal forms "
   "before inspecting Python helpers. Named Scheme artifacts can be created, listed, loaded, "
   "disabled, or exported with the extension tool; use them when a successful live "
   "change should persist beyond this process. Thinking is "
   "already carried separately; never emit think tags or repeat a final answer in content. "
   "The live context hook is agent-select-context. It receives user text and returns "
   "a list of project-relative files. If asked to repair context selection, redefine "
   "that function with live_eval; string-contains and boolean string-contains? are "
   "available, and the new generation applies on the next turn. "
   "This project is Scheme running on GNU Guile; guild's .go outputs are Guile object files, not Go source or binaries."))

;; Tool names are data owned by the live image. The stable runtime owns their
;; capability checks and implementations.
(define agent-tools '(read rg write edit shell live_eval extension))

;; The prototype deliberately supports only deny and ask. A live image cannot
;; silently broaden the stable runtime's authority.
(define agent-shell-policy 'ask)

;; Return project-relative files to inject as authoritative context for a turn.
;; The stable runtime validates and reads them through the constrained read tool.
(define (agent-select-context text)
  '())

(define (agent-transform-user text)
  text)

(define (agent-demo-response text)
  (string-append
   "[" agent-name " · live generation] "
   (agent-transform-user text)))
