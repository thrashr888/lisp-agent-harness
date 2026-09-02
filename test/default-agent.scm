(use-modules (srfi srfi-64)
             (live-agent generation))

(test-begin "default agent")

(define source-path "agent/default.scm")
(define generation
  (build-generation 1 source-path (read-source-file source-path) '()))

(test-equal "defaults to installed tool-capable Ollama model"
  "qwen3.8:27b-mlx"
  (generation-ref generation 'agent-model))

(test-equal "defaults to local Ollama OpenAI endpoint"
  "http://127.0.0.1:11434/v1"
  (generation-ref generation 'agent-base-url))

(test-eq "Ollama does not require a credential environment variable"
  #f
  (generation-ref generation 'agent-api-key-environment))

(test-end "default agent")
