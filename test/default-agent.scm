(use-modules (srfi srfi-64)
             (live-agent generation))

(test-begin "default agent")

(define source-path "agent/default.scm")
(define generation
  (build-generation 1 source-path (read-source-file source-path) '()))

(test-equal "defaults to installed tool-capable Ollama model"
  "qwen3.8:27b-mlx"
  (generation-ref generation 'agent-model))

(test-eq "defaults to native Ollama transport"
  'ollama
  (generation-ref generation 'agent-provider))

(test-equal "defaults to local native Ollama endpoint"
  "http://127.0.0.1:11434"
  (generation-ref generation 'agent-base-url))

(test-eq "Ollama does not require a credential environment variable"
  #f
  (generation-ref generation 'agent-api-key-environment))

(test-assert "streams output by default"
  (generation-ref generation 'agent-stream?))

(test-eq "uses low thinking by default"
  'low
  (generation-ref generation 'agent-thinking))

(test-assert "agent can change its constrained live image"
  (memq 'live_eval (generation-ref generation 'agent-tools)))

(test-end "default agent")
