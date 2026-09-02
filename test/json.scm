(use-modules (srfi srfi-64)
             (live-agent json))

(test-begin "json")

(define value
  (json-object
   (cons "text" "line one\nline two ☃")
   (cons "count" 3)
   (cons "enabled" #t)
   (cons "nothing" json-null)
   (cons "items" (json-array "a" 2 #f))))

(define round-trip (json-read (json-write value)))

(test-equal "object string round trip"
  "line one\nline two ☃"
  (json-object-ref round-trip "text"))

(test-equal "array round trip"
  3
  (length (json-array-items (json-object-ref round-trip "items"))))

(test-equal "unicode surrogate pair"
  "😀"
  (json-object-ref (json-read "{\"face\":\"\\uD83D\\uDE00\"}") "face"))

(test-error "reject trailing input" #t (json-read "{} nope"))

(test-end "json")
