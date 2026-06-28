;;; test-sprite-direct.el --- ERT tests for sprite-direct.el -*- lexical-binding: t -*-

;; Run inside a live Emacs session:
;;   (ert "^sprite-direct/")
;;
;; Batch run:
;;   emacs --batch -L ~/.emacs.d/external/sprite \
;;     -l ~/.emacs.d/external/sprite/test/test-sprite-direct.el \
;;     --eval '(ert-run-tests-batch-and-exit "sprite-direct/")'

;;; Commentary:
;;
;; Unit tests for sprite-direct.el.  All tests are isolated: auth and socket
;; lookups are intercepted with cl-letf or temporary files; no live daemons
;; or real sockets are required.
;;

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'map)
(require 'sprite-direct)

;; Declare server.el variables as special so let-bindings in tests
;; create dynamic bindings visible to sprite-direct--read-auth-key.
(defvar server-auth-dir)
(defvar server-socket-dir)

;;;; Wire-protocol encoding

(ert-deftest sprite-direct/encode-ampersand ()
  "`sprite-direct--encode' encodes & as &&."
  (should (equal "&&" (sprite-direct--encode "&"))))

(ert-deftest sprite-direct/encode-dash ()
  "`sprite-direct--encode' encodes - as &-."
  (should (equal "&-" (sprite-direct--encode "-"))))

(ert-deftest sprite-direct/encode-space ()
  "`sprite-direct--encode' encodes space as &_."
  (should (equal "&_" (sprite-direct--encode " "))))

(ert-deftest sprite-direct/encode-newline ()
  "`sprite-direct--encode' encodes newline as &n."
  (should (equal "&n" (sprite-direct--encode "\n"))))

(ert-deftest sprite-direct/encode-plain-string ()
  "`sprite-direct--encode' leaves ordinary characters unchanged."
  (should (equal "hello" (sprite-direct--encode "hello"))))

(ert-deftest sprite-direct/encode-mixed ()
  "`sprite-direct--encode' handles strings with multiple special characters."
  (should (equal "hello&_world&n" (sprite-direct--encode "hello world\n"))))

(ert-deftest sprite-direct/encode-lisp-form ()
  "`sprite-direct--encode' encodes a printed Lisp form correctly."
  (should (equal "(my&-symbol&_42)" (sprite-direct--encode "(my-symbol 42)"))))

(ert-deftest sprite-direct/encode-empty ()
  "`sprite-direct--encode' handles the empty string."
  (should (equal "" (sprite-direct--encode ""))))

;;;; Wire-protocol decoding

(ert-deftest sprite-direct/decode-ampersand ()
  "`sprite-direct--decode' decodes && as &."
  (should (equal "&" (sprite-direct--decode "&&"))))

(ert-deftest sprite-direct/decode-dash ()
  "`sprite-direct--decode' decodes &- as -."
  (should (equal "-" (sprite-direct--decode "&-"))))

(ert-deftest sprite-direct/decode-space ()
  "`sprite-direct--decode' decodes &_ as space."
  (should (equal " " (sprite-direct--decode "&_"))))

(ert-deftest sprite-direct/decode-newline ()
  "`sprite-direct--decode' decodes &n as newline."
  (should (equal "\n" (sprite-direct--decode "&n"))))

(ert-deftest sprite-direct/decode-plain ()
  "`sprite-direct--decode' leaves ordinary characters unchanged."
  (should (equal "hello" (sprite-direct--decode "hello"))))

(ert-deftest sprite-direct/decode-empty ()
  "`sprite-direct--decode' handles the empty string."
  (should (equal "" (sprite-direct--decode ""))))

;;;; Encode/decode roundtrip

(ert-deftest sprite-direct/encode-decode-roundtrip ()
  "decode(encode(s)) = s for a variety of inputs."
  (seq-do
   (lambda (s)
     (should (equal s (sprite-direct--decode (sprite-direct--encode s)))))
   (list ""
         "hello world"
         "my-symbol"
         "line1\nline2"
         "&embedded&"
         "(+ 1 2)"
         "(my-list 'of \"values\")"
         "a & b - c\nd")))

;;;; TCP connection parsing

(ert-deftest sprite-direct/parse-tcp-valid ()
  "`sprite-direct--parse-tcp' parses a HOST:PORT:KEY string correctly."
  (let ((conn (sprite-direct--parse-tcp "127.0.0.1:12345:authkey")))
    (should conn)
    (should (eq 'tcp (map-elt conn :type)))
    (should (equal "127.0.0.1" (map-elt conn :host)))
    (should (= 12345 (map-elt conn :port)))
    (should (equal "authkey" (map-elt conn :key)))))

(ert-deftest sprite-direct/parse-tcp-dotted-host ()
  "`sprite-direct--parse-tcp' handles IPv4 addresses."
  (let ((conn (sprite-direct--parse-tcp "192.168.1.100:9999:secretkey123")))
    (should conn)
    (should (equal "192.168.1.100" (map-elt conn :host)))
    (should (= 9999 (map-elt conn :port)))
    (should (equal "secretkey123" (map-elt conn :key)))))

(ert-deftest sprite-direct/parse-tcp-localhost ()
  "`sprite-direct--parse-tcp' handles localhost."
  (let ((conn (sprite-direct--parse-tcp "localhost:1234:mykey")))
    (should conn)
    (should (equal "localhost" (map-elt conn :host)))
    (should (= 1234 (map-elt conn :port)))
    (should (equal "mykey" (map-elt conn :key)))))

(ert-deftest sprite-direct/parse-tcp-not-a-tcp-string ()
  "`sprite-direct--parse-tcp' returns nil for a bare socket name."
  (should-not (sprite-direct--parse-tcp "work.0.render")))

(ert-deftest sprite-direct/parse-tcp-plain-name ()
  "`sprite-direct--parse-tcp' returns nil for a plain name."
  (should-not (sprite-direct--parse-tcp "my-daemon")))

(ert-deftest sprite-direct/parse-tcp-empty ()
  "`sprite-direct--parse-tcp' returns nil for an empty string."
  (should-not (sprite-direct--parse-tcp "")))

;;;; Connection spec construction

(ert-deftest sprite-direct/parse-connection-tcp-string ()
  "`sprite-direct--parse-connection' produces a TCP plist for HOST:PORT:KEY."
  (let ((conn (sprite-direct--parse-connection "127.0.0.1:4242:key123")))
    (should (eq 'tcp (map-elt conn :type)))
    (should (equal "127.0.0.1" (map-elt conn :host)))
    (should (= 4242 (map-elt conn :port)))
    (should (equal "key123" (map-elt conn :key)))))

(ert-deftest sprite-direct/parse-connection-unix-name ()
  "`sprite-direct--parse-connection' produces a Unix plist for a socket name."
  (cl-letf (((symbol-function 'sprite-direct--read-auth-key)
              (lambda (_) "testauth"))
             ((symbol-function 'sprite-direct--socket-path)
              (lambda (name) (concat "/tmp/test-sockets/" name))))
    (let ((conn (sprite-direct--parse-connection "work.0.render")))
      (should (eq 'unix (map-elt conn :type)))
      (should (equal "work.0.render" (map-elt conn :name)))
      (should (equal "/tmp/test-sockets/work.0.render" (map-elt conn :path)))
      (should (equal "testauth" (map-elt conn :key))))))

(ert-deftest sprite-direct/parse-connection-unix-missing-auth ()
  "`sprite-direct--parse-connection' sets :key nil when auth is unavailable."
  (cl-letf (((symbol-function 'sprite-direct--read-auth-key) (lambda (_) nil))
             ((symbol-function 'sprite-direct--socket-path) (lambda (n) n)))
    (let ((conn (sprite-direct--parse-connection "work.0.render")))
      (should (eq 'unix (map-elt conn :type)))
      (should-not (map-elt conn :key)))))

;;;; Response parsing

(ert-deftest sprite-direct/parse-response-integer ()
  "`sprite-direct--parse-response' reads an integer result."
  (should (= 3 (sprite-direct--parse-response "-print 3\n"))))

(ert-deftest sprite-direct/parse-response-nil ()
  "`sprite-direct--parse-response' reads nil as nil."
  (should-not (sprite-direct--parse-response "-print nil\n")))

(ert-deftest sprite-direct/parse-response-t ()
  "`sprite-direct--parse-response' reads t."
  (should (eq t (sprite-direct--parse-response "-print t\n"))))

(ert-deftest sprite-direct/parse-response-string-with-spaces ()
  "`sprite-direct--parse-response' decodes and reads a string with spaces."
  ;; Wire: "hello world" → prin1 → "\"hello world\"" → encode → "\"hello&_world\""
  (should (equal "hello world"
                 (sprite-direct--parse-response "-print \"hello&_world\"\n"))))

(ert-deftest sprite-direct/parse-response-list ()
  "`sprite-direct--parse-response' decodes and reads a list."
  ;; (1 2 3) → encode → (1&_2&_3)
  (should (equal '(1 2 3)
                 (sprite-direct--parse-response "-print (1&_2&_3)\n"))))

(ert-deftest sprite-direct/parse-response-symbol-with-dash ()
  "`sprite-direct--parse-response' decodes a symbol containing a dash."
  ;; 'my-symbol → "my-symbol" → encode → "my&-symbol"
  (should (eq 'my-symbol
              (sprite-direct--parse-response "-print my&-symbol\n"))))

(ert-deftest sprite-direct/parse-response-error-returns-nil ()
  "`sprite-direct--parse-response' returns nil for -error responses."
  (should-not (sprite-direct--parse-response "-error Some&_error\n")))

(ert-deftest sprite-direct/parse-response-nil-input ()
  "`sprite-direct--parse-response' returns nil for nil input."
  (should-not (sprite-direct--parse-response nil)))

(ert-deftest sprite-direct/parse-response-empty-string ()
  "`sprite-direct--parse-response' returns nil for an empty string."
  (should-not (sprite-direct--parse-response "")))

(ert-deftest sprite-direct/parse-response-no-newline ()
  "`sprite-direct--parse-response' returns nil when no newline terminates."
  (should-not (sprite-direct--parse-response "-print 3")))

(ert-deftest sprite-direct/parse-response-skips-emacs-pid-line ()
  "`sprite-direct--parse-response' skips -emacs-pid preamble lines."
  (should (= 42
             (sprite-direct--parse-response "-emacs-pid 12345\n-print 42\n"))))

(ert-deftest sprite-direct/parse-response-prefers-first-print ()
  "`sprite-direct--parse-response' returns the value from the first -print line."
  (should (= 1
             (sprite-direct--parse-response "-print 1\n-print 2\n"))))

;;;; Auth file reading

(ert-deftest sprite-direct/read-auth-key-present ()
  "`sprite-direct--read-auth-key' returns the trimmed key from the auth file."
  (let* ((tmpdir (make-temp-file "sprite-direct-test-" t))
         (keyfile (expand-file-name "myserver" tmpdir)))
    (unwind-protect
        (let ((server-auth-dir tmpdir))
          (with-temp-file keyfile
            (insert "my-secret-auth-key\n"))
          (should (equal "my-secret-auth-key"
                         (sprite-direct--read-auth-key "myserver"))))
      (delete-directory tmpdir t))))

(ert-deftest sprite-direct/read-auth-key-absent ()
  "`sprite-direct--read-auth-key' returns nil when the auth file is missing."
  (let ((server-auth-dir "/tmp/nonexistent-dir-sprite-direct-test/"))
    (should-not (sprite-direct--read-auth-key "nonexistent-server"))))

(ert-deftest sprite-direct/read-auth-key-trims-whitespace ()
  "`sprite-direct--read-auth-key' strips trailing whitespace from the key."
  (let* ((tmpdir (make-temp-file "sprite-direct-test-" t))
         (keyfile (expand-file-name "srv" tmpdir)))
    (unwind-protect
        (let ((server-auth-dir tmpdir))
          (with-temp-file keyfile
            (insert "   trimmed-key   \n"))
          (should (equal "trimmed-key"
                         (sprite-direct--read-auth-key "srv"))))
      (delete-directory tmpdir t))))

;;;; TCP server file

(ert-deftest sprite-direct/read-tcp-server-file-present ()
  "`sprite-direct-read-tcp-server-file' returns the trimmed file contents."
  (let ((tmpfile (make-temp-file "sprite-direct-tcp-")))
    (unwind-protect
        (progn
          (with-temp-file tmpfile
            (insert "127.0.0.1:1234:secretkey\n"))
          (should (equal "127.0.0.1:1234:secretkey"
                         (sprite-direct-read-tcp-server-file tmpfile))))
      (delete-file tmpfile))))

(ert-deftest sprite-direct/read-tcp-server-file-absent ()
  "`sprite-direct-read-tcp-server-file' returns nil for a missing file."
  (should-not (sprite-direct-read-tcp-server-file "/nonexistent/path/server")))

(provide 'test-sprite-direct)
;;; test-sprite-direct.el ends here
