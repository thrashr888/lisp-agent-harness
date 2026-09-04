;; Live Agent extension: openai-gateway
;; Route this session through OpenAI's efficient coding-oriented mini model.

(begin
  (set! agent-provider 'openai)
  (set! agent-model "gpt-5.4-mini")
  (set! agent-base-url "https://api.openai.com/v1")
  (set! agent-api-key-environment "OPENAI_API_KEY")
  (set! agent-stream? #f)
  (set! agent-thinking #f))
