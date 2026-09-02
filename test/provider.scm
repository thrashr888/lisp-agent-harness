(use-modules (srfi srfi-64)
             (live-agent json)
             (live-agent provider))

(test-begin "provider")

(define text-completion
  (parse-completion-response
   "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"hello\"}}]}"))

(test-equal "parses assistant text" "hello" (completion-content text-completion))
(test-equal "text response has no calls" 0 (length (completion-tool-calls text-completion)))

(define tool-completion
  (parse-completion-response
   (string-append
    "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":null,"
    "\"tool_calls\":[{\"id\":\"call_1\",\"type\":\"function\","
    "\"function\":{\"name\":\"read\",\"arguments\":\"{\\\"path\\\":\\\"README.md\\\"}\"}}]}}]}")))

(define call (car (completion-tool-calls tool-completion)))
(test-equal "parses tool name" "read" (tool-call-name call))
(test-equal "parses nested arguments"
  "README.md"
  (json-object-ref (tool-call-arguments call) "path"))

(define ollama-completion
  (parse-ollama-response
   (string-append
    "{\"message\":{\"role\":\"assistant\",\"content\":\"\","
    "\"thinking\":\"I should read it.\",\"tool_calls\":["
    "{\"id\":\"call_native\",\"function\":{\"name\":\"read\","
    "\"arguments\":{\"path\":\"LICENSE\"}}}]},\"done\":true,"
    "\"prompt_eval_count\":12,\"eval_count\":7}")))

(test-equal "parses native Ollama thinking"
  "I should read it."
  (completion-thinking ollama-completion))
(test-equal "parses native Ollama object arguments"
  "LICENSE"
  (json-object-ref
   (tool-call-arguments (car (completion-tool-calls ollama-completion)))
   "path"))

(define thinking-off-request
  (make-ollama-request
   "fixture" (list (make-message "user" "hello")) '() #t #f))
(test-eq "serializes explicit thinking false"
  #f
  (json-object-ref thinking-off-request "think"))

(define leveled-request
  (make-ollama-request
   "fixture" (list (make-message "user" "hello")) '() #t 'medium))
(test-equal "serializes model-specific thinking level"
  "medium"
  (json-object-ref leveled-request "think"))

(test-end "provider")
