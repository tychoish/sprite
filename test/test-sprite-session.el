;;; test-sprite-session.el --- ERT tests for sprite-session.el -*- lexical-binding: t; no-byte-compile: t; -*-

;; Run inside a live Emacs session:
;;   (ert "^sprite-session/")
;;
;; Batch run:
;;   emacs --batch -L ~/.emacs.d/external/sprite \
;;     -l ~/.emacs.d/external/sprite/test/test-sprite-session.el \
;;     --eval '(ert-run-tests-batch-and-exit "sprite-session/")'

;;; Commentary:
;;
;; Unit tests for sprite-session.el.  Bindings are built from plain
;; string/integer/string values directly; no `sprite-mcp' struct or
;; other daemon-spawning dependency is ever involved.

;;; Code:

(require 'ert)
(require 'cl-lib)

(defvar server-use-tcp)
(defvar server-auth-dir)

(require 'sprite)
(require 'sprite-session)

;;;; Helpers

(defun sprite-session-test--worktree (sprite-id)
  "Return a fake worktree path for SPRITE-ID."
  (format "/tmp/wt-%s" sprite-id))

(defmacro sprite-session-test/with-registry (&rest body)
  "Run BODY with a fresh `sprite-session-registry'."
  (declare (indent 0))
  `(let ((sprite-session-registry (make-hash-table :test #'equal)))
     ,@body))

;;;; bind / lookup / unbind round-trip

(ert-deftest sprite-session/bind-lookup-unbind-round-trip ()
  (sprite-session-test/with-registry
    (sprite-session-bind "session-a" "sp-1" 12345 (sprite-session-test--worktree "sp-1") 'agent-shell)
    (let ((plist (sprite-session-lookup "session-a")))
      (should (equal "sp-1" (plist-get plist :sprite-id)))
      (should (equal 12345 (plist-get plist :port)))
      (should (equal "/tmp/wt-sp-1" (plist-get plist :worktree)))
      (should (eq 'agent-shell (plist-get plist :driver))))
    (should (sprite-session-unbind "session-a"))
    (should (null (sprite-session-lookup "session-a")))))

(ert-deftest sprite-session/lookup-unbound-session-returns-nil ()
  (sprite-session-test/with-registry
    (should (null (sprite-session-lookup "nonexistent")))))

(ert-deftest sprite-session/unbind-unbound-session-returns-nil ()
  (sprite-session-test/with-registry
    (should (null (sprite-session-unbind "nonexistent")))))

;;;; idempotent re-bind

(ert-deftest sprite-session/rebind-same-sprite-id-is-idempotent ()
  (sprite-session-test/with-registry
    (sprite-session-bind "session-a" "sp-1" 12345 (sprite-session-test--worktree "sp-1") 'agent-shell)
    ;; Re-bind to the same sprite-id but different port/worktree (as if
    ;; freshly looked up again) -- should not error, and should update
    ;; the stored plist.
    (sprite-session-bind "session-a" "sp-1" 54321 "/tmp/wt-sp-1" 'agent-shell)
    (let ((plist (sprite-session-lookup "session-a")))
      (should (equal "sp-1" (plist-get plist :sprite-id))))))

;;;; user-error on rebind to a different sprite

(ert-deftest sprite-session/rebind-different-sprite-signals-user-error ()
  (sprite-session-test/with-registry
    (sprite-session-bind "session-a" "sp-1" 12345 (sprite-session-test--worktree "sp-1") 'agent-shell)
    (should-error
     (sprite-session-bind "session-a" "sp-2" 12346 (sprite-session-test--worktree "sp-2") 'agent-shell)
     :type 'user-error)
    ;; The original binding is left untouched.
    (should (equal "sp-1" (plist-get (sprite-session-lookup "session-a") :sprite-id)))))

(ert-deftest sprite-session/rebind-different-sprite-after-unbind-succeeds ()
  (sprite-session-test/with-registry
    (sprite-session-bind "session-a" "sp-1" 12345 (sprite-session-test--worktree "sp-1") 'agent-shell)
    (sprite-session-unbind "session-a")
    (sprite-session-bind "session-a" "sp-2" 12346 (sprite-session-test--worktree "sp-2") 'agent-shell)
    (should (equal "sp-2" (plist-get (sprite-session-lookup "session-a") :sprite-id)))))

;;;; sprites-for-driver filtering

(ert-deftest sprite-session/sprites-for-driver-filters-by-driver ()
  (sprite-session-test/with-registry
    (sprite-session-bind "session-a" "sp-1" 12345 (sprite-session-test--worktree "sp-1") 'agent-shell)
    (sprite-session-bind "session-b" "sp-2" 12346 (sprite-session-test--worktree "sp-2") 'asq)
    (sprite-session-bind "session-c" "sp-3" 12347 (sprite-session-test--worktree "sp-3") 'agent-shell)
    (let ((agent-shell-sessions (sprite-session-sprites-for-driver 'agent-shell)))
      (should (= 2 (length agent-shell-sessions)))
      (should (equal '("session-a" "session-c")
                     (sort (mapcar #'car agent-shell-sessions) #'string<)))
      (should (equal '("sp-1" "sp-3")
                     (sort (mapcar (lambda (pair) (plist-get (cdr pair) :sprite-id))
                                   agent-shell-sessions)
                           #'string<))))
    (let ((asq-sessions (sprite-session-sprites-for-driver 'asq)))
      (should (= 1 (length asq-sessions)))
      (should (equal "session-b" (caar asq-sessions))))
    (should (null (sprite-session-sprites-for-driver 'gptel)))))

;;;; unbind never calls anything kill/stop-shaped

(ert-deftest sprite-session/unbind-does-not-call-kill-or-stop ()
  "Unbinding a session must never terminate the underlying sprite daemon."
  (sprite-session-test/with-registry
    (let ((stop-called nil))
      (cl-letf (((symbol-function 'sprite-stop)
                 (lambda (&rest _) (setq stop-called t))))
        (sprite-session-bind "session-a" "sp-1" 12345 (sprite-session-test--worktree "sp-1") 'agent-shell)
        (sprite-session-unbind "session-a")
        (should-not stop-called)))))

(provide 'test-sprite-session)
;;; test-sprite-session.el ends here
