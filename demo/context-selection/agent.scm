;; A deliberately flawed live image for the context-selection demo.

(define agent-name "context-selection-demo")
(define agent-provider 'ollama)
(define agent-model "qwen3.8:27b-mlx")
(define agent-base-url "http://127.0.0.1:11434")
(define agent-api-key-environment #f)
(define agent-stream? #t)
(define agent-thinking #f)
(define agent-max-tool-rounds 6)
(define agent-compaction-threshold 80)
(define agent-compaction-keep-recent 24)

(define agent-system-prompt
  (string-append
   "You are demonstrating a live, user-programmable context selector. "
   "Be extremely concise. Answer only from the authoritative context injected for "
   "this turn and always name its selected source path. Do not infer, inspect, or "
   "mention any other source. On the first port question, answer from the injected "
   "legacy context and do not call a tool. Do not mutate live behavior unless the "
   "current user message explicitly asks you to fix it. The selector is the Scheme "
   "function agent-select-context; it accepts user text and returns project-relative "
   "file paths. When explicitly asked to repair it, use live_eval with a new define "
   "form. The function must always return a list of paths, never a bare string. For "
   "this repair, port or deploy queries should return "
   "(list \"demo/context-selection/context/current-runbook.md\") and other queries "
   "should return the empty list. Before live_eval, say in one natural sentence which "
   "function will change, why, and what the retry should select. After it succeeds, "
   "concisely report the before and after generation IDs and invite a retry. The "
   "boolean helper string-contains? and cond else are available. A successful patch "
   "activates on the next turn. Never emit think tags or repeat a final answer."))

(define agent-tools '(live_eval))
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
