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
  (and (tool-result-success? read-result)
       (string-contains (tool-result-output read-result)
                        "# Lisp Agent Harness")))

(define escaped-read
  (execute-tool
   "read"
   (json-object (cons "path" "/etc/hosts"))
   root
   'deny
   (lambda _ #f)))

(test-assert "read rejects paths outside project"
  (and (not (tool-result-success? escaped-read))
       (string-contains (tool-result-output escaped-read)
                        "escapes the project root")))

(define confirm-called? #f)
(define denied-shell
  (execute-tool
   "shell"
   (json-object (cons "command" "echo should-not-run"))
   root
   'deny
   (lambda _ (set! confirm-called? #t) #t)))

(test-assert "deny policy blocks shell"
  (and (not (tool-result-success? denied-shell))
       (string-contains (tool-result-output denied-shell)
                        "denied by the live image")))
(test-assert "deny policy never prompts" (not confirm-called?))

(define tool-root
  (string-append "/tmp/lisp-agent-tools-test-" (number->string (getpid))))
(system* "mkdir" "-p" tool-root)

(define write-result
  (execute-tool
   "write"
   (json-object (cons "path" "notes.txt")
                (cons "content" "alpha port 8080\nalpha port 8080\n"))
   tool-root 'deny (lambda _ #f)))

(test-assert "write atomically creates a project file"
  (and (tool-result-success? write-result)
       (file-exists? (string-append tool-root "/notes.txt"))))

(define ambiguous-edit
  (execute-tool
   "edit"
   (json-object (cons "path" "notes.txt")
                (cons "old_text" "8080")
                (cons "new_text" "9443"))
   tool-root 'deny (lambda _ #f)))

(test-assert "edit rejects ambiguous replacements by default"
  (and (not (tool-result-success? ambiguous-edit))
       (string-contains (tool-result-output ambiguous-edit) "ambiguous")))

(define all-edit
  (execute-tool
   "edit"
   (json-object (cons "path" "notes.txt")
                (cons "old_text" "8080")
                (cons "new_text" "9443")
                (cons "replace_all" #t))
   tool-root 'deny (lambda _ #f)))

(test-assert "edit can replace every exact occurrence explicitly"
  (and (tool-result-success? all-edit)
       (string-contains (tool-result-output all-edit) "2 occurrences")))

(define rg-result
  (execute-tool
   "rg"
   (json-object (cons "query" "9443") (cons "path" "."))
   tool-root 'deny (lambda _ #f)))

(test-assert "rg searches without shell authority"
  (and (tool-result-success? rg-result)
       (string-contains (tool-result-output rg-result) "notes.txt:1")
       (string-contains (tool-result-output rg-result) "notes.txt:2")))

(define escaped-write
  (execute-tool
   "write"
   (json-object (cons "path" "../escape.txt") (cons "content" "no"))
   tool-root 'deny (lambda _ #f)))

(test-assert "write rejects paths outside the project"
  (and (not (tool-result-success? escaped-write))
       (string-contains (tool-result-output escaped-write)
                        "escapes the project root")))

(test-end "tools")
