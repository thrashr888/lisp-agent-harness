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

(test-end "provider")
