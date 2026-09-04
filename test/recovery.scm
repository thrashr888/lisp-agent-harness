(use-modules (srfi srfi-64)
             (live-agent json)
             (live-agent recovery))

(test-begin "recovery")

(define root
  (string-append "/tmp/shift-recovery-test-" (number->string (getpid))))
(system* "mkdir" "-p" root)

(test-eq "no pending record" #f (recovery-read root))
(recovery-write!
 root "read" (json-object (cons "path" "README.md")) 7)
(define pending (recovery-read root))
(test-equal "records tool" "read" (json-object-ref pending "tool"))
(test-equal "records generation" 7 (json-object-ref pending "generation_id"))
(test-equal "records arguments"
  "README.md"
  (json-object-ref (json-object-ref pending "arguments") "path"))
(recovery-clear! root)
(test-eq "clear removes the record" #f (recovery-read root))

(test-end "recovery")
