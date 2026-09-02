;; A deliberately flawed live image for the context-selection demo.

(define agent-name "context-selection-demo")
(define agent-provider 'ollama)
(define agent-model "qwen3.8:27b-mlx")
(define agent-base-url "http://127.0.0.1:11434")
(define agent-api-key-environment #f)
(define agent-stream? #t)
(define agent-thinking #t)
(define agent-max-tool-rounds 6)

(define agent-system-prompt
  (string-append
   "You are demonstrating a live, user-programmable context selector. "
   "Answer factual questions from the authoritative context injected for this turn. "
   "Always name the selected source path beside the answer so a bad choice is obvious. "
   "The selector is the Scheme function agent-select-context; it accepts user text "
   "and returns project-relative file paths. If the user says the selected context is "
   "stale or wrong, repair that function with live_eval rather than shell. Use a new "
   "define form, explain that it activates on the next turn, and invite the user to retry. "
   "The boolean helper string-contains? is available in the live language. "
   "For the intended repair, deployment questions should select "
   "demo/context-selection/context/current-runbook.md. Never claim the current turn "
   "used a generation that only activates after this turn."))

(define agent-tools '(read shell live_eval))
(define agent-shell-policy 'deny)

;; Intentionally wrong: the first turn selects the obsolete runbook.
(define (agent-select-context text)
  (let ((query (string-downcase text)))
    (if (or (string-contains query "atlas")
            (string-contains query "deploy")
            (string-contains query "port"))
        '("demo/context-selection/context/legacy-runbook.md")
        '())))

(define (agent-transform-user text)
  text)

(define (agent-demo-response text)
  (string-append "[context demo] " text))
