(use-modules (srfi srfi-64)
             (live-agent json)
             (live-agent tools))

(test-begin "tools")

(define root (getcwd))

(define read-result
  (execute-tool
   "read"
   (json-object (cons "path" "README.md"))
   root
   'deny
   (lambda _ #f)))

(test-assert "read stays inside project"
  (string-contains read-result "# Lisp Agent Harness"))

(define escaped-read
  (execute-tool
   "read"
   (json-object (cons "path" "/etc/hosts"))
   root
   'deny
   (lambda _ #f)))

(test-assert "read rejects paths outside project"
  (string-contains escaped-read "escapes the project root"))

(define confirm-called? #f)
(define denied-shell
  (execute-tool
   "shell"
   (json-object (cons "command" "echo should-not-run"))
   root
   'deny
   (lambda _ (set! confirm-called? #t) #t)))

(test-assert "deny policy blocks shell"
  (string-contains denied-shell "denied by the live image"))
(test-assert "deny policy never prompts" (not confirm-called?))

(test-end "tools")
