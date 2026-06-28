;;; test-sprite-direct-integration.el --- Integration tests for sprite-direct.el -*- lexical-binding: t -*-

;; Batch run (requires a writable socket dir):
;;   emacs --batch -L ~/.emacs.d/external/sprite \
;;     -l ~/.emacs.d/external/sprite/test/test-sprite-direct-integration.el \
;;     --eval '(ert-run-tests-batch-and-exit "sprite-direct-\\(proc\\|buf\\)/")'

;;; Commentary:
;;
;; Integration tests that exercise sprite-direct.el against live Emacs daemons.
;; No mocking: real sockets, real server wire protocol, real subprocess output.
;;
;; Test suites:
;;
;;   sprite-direct-proc/* — daemon lifecycle and basic connectivity.
;;     Each test spawns a dedicated daemon, verifies the behaviour under test,
;;     then kills it.  Tests are independent and always start clean.
;;
;;   sprite-direct-buf/* — buffer create / insert / read / local-var operations.
;;     Uses an existing live sprite from the session registry when available,
;;     otherwise spawns a shared daemon for the suite and reuses it across all
;;     buffer tests.  Tests skip when no daemon can be made ready.
;;
;; Both suites require a writable `server-socket-dir'.  They are intentionally
;; omitted from the normal unit-test batch run and must be invoked explicitly.
;;

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'map)
(require 'subr-x)
(require 'sprite-direct)

(declare-function sprite--registry-all "sprite")
(declare-function sprite-name          "sprite")

(defvar server-socket-dir)
(defvar server-auth-dir)

;;;; Configuration

(defconst sprite-direct-test--name "sprite-direct-test"
  "Socket name for the integration-test daemon.")

(defconst sprite-direct-test--start-timeout 15.0
  "Seconds to wait for a freshly spawned daemon's socket + auth to appear.")

(defconst sprite-direct-test--eval-timeout 5.0
  "Per-operation timeout passed to blocking sprite-direct calls.")

;;;; Daemon lifecycle helpers

(defun sprite-direct-test--socket-ready-p (name)
  "Return t when NAME's socket is present and accepts connections.
Probes via a transient network process rather than requiring an auth file,
since Emacs 29+ authenticates local sockets via peer UID without cookie files."
  (when-let* ((path (sprite-direct--socket-path name))
              ((file-exists-p path)))
    (condition-case nil
        (let ((proc (make-network-process
                     :name " sprite-direct-probe"
                     :family 'local
                     :service path
                     :noquery t)))
          (delete-process proc)
          t)
      (error nil))))

(defun sprite-direct-test--wait-for-socket (name)
  "Poll until NAME is ready or `sprite-direct-test--start-timeout' elapses.
Returns t when ready, nil on timeout."
  (let ((deadline (+ (float-time) sprite-direct-test--start-timeout)))
    (while (and (not (sprite-direct-test--socket-ready-p name))
                (< (float-time) deadline))
      (sleep-for 0.2))
    (sprite-direct-test--socket-ready-p name)))

(defun sprite-direct-test--spawn-daemon (name)
  "Start `emacs --daemon=NAME --no-init-file'; return the process.
Uses the same Emacs binary as the calling process."
  (start-process (format "sprite-direct-test-%s" name)
                 nil
                 (expand-file-name invocation-name invocation-directory)
                 (format "--daemon=%s" name)
                 "--no-init-file"
                 "--no-site-file"))

(defun sprite-direct-test--kill-daemon (name proc)
  "Shut down daemon NAME and clean up files.
Sends `kill-emacs' first; force-kills PROC if still alive after 1 s."
  (condition-case nil
      (let ((sprite-direct-blocking-timeout 2.0))
        (sprite-direct-call-and-read name '(kill-emacs 0)))
    (error nil))
  (sleep-for 0.5)
  (when (and proc (process-live-p proc))
    (delete-process proc))
  (when-let* ((sock (sprite-direct--socket-path name))
              ((file-exists-p sock)))
    (delete-file sock))
  (when (and (boundp 'server-auth-dir) server-auth-dir)
    (let ((auth (expand-file-name name server-auth-dir)))
      (when (file-exists-p auth)
        (delete-file auth)))))

(defun sprite-direct-test--find-live-sprite ()
  "Return the name of a reachable registered sprite, or nil."
  (when (fboundp 'sprite--registry-all)
    (when-let* ((s (seq-find
                    (lambda (s)
                      (sprite-direct-test--socket-ready-p (sprite-name s)))
                    (sprite--registry-all))))
      (sprite-name s))))

(defun sprite-direct-test--resolve-target ()
  "Return the daemon name to use for buffer-suite tests.
Prefers: existing test daemon → live registered sprite → test daemon (spawn)."
  (if (sprite-direct-test--socket-ready-p sprite-direct-test--name)
      sprite-direct-test--name
    (or (sprite-direct-test--find-live-sprite)
        sprite-direct-test--name)))

(defun sprite-direct-test--unique-buf ()
  "Return a unique remote buffer name for test isolation."
  (format " *sdtest-%d*" (abs (random))))

;;;; Macros

(defmacro sprite-direct-test/with-fresh-daemon (&rest body)
  "Spawn a clean daemon, run BODY, then kill it unconditionally.
Kills any stale daemon of the same name first.  Skips when the daemon
cannot start within `sprite-direct-test--start-timeout'."
  (declare (indent 0))
  (let ((gproc (make-symbol "proc")))
    `(let (,gproc)
       (when (sprite-direct-test--socket-ready-p sprite-direct-test--name)
         (sprite-direct-test--kill-daemon sprite-direct-test--name nil)
         (sleep-for 0.5))
       (unwind-protect
           (progn
             (setq ,gproc (sprite-direct-test--spawn-daemon sprite-direct-test--name))
             (unless (sprite-direct-test--wait-for-socket sprite-direct-test--name)
               (ert-skip "Test daemon did not become ready within timeout"))
             ,@body)
         (sprite-direct-test--kill-daemon sprite-direct-test--name ,gproc)))))

(defmacro sprite-direct-test/with-daemon (var &rest body)
  "Bind VAR to a conn for the integration daemon and evaluate BODY.
Reuses an existing live daemon when available; spawns one otherwise.
Only kills daemons that this macro started.  Skips on timeout."
  (declare (indent 1))
  (let ((gname  (make-symbol "name"))
        (gowned (make-symbol "owned"))
        (gproc  (make-symbol "proc")))
    `(let ((,gname  (sprite-direct-test--resolve-target))
           (,gowned nil)
           (,gproc  nil))
       (unwind-protect
           (progn
             (unless (sprite-direct-test--socket-ready-p ,gname)
               (setq ,gowned t)
               (setq ,gproc (sprite-direct-test--spawn-daemon ,gname))
               (unless (sprite-direct-test--wait-for-socket ,gname)
                 (ert-skip "Test daemon did not become ready within timeout")))
             (let ((,var (sprite-direct-open ,gname)))
               ,@body))
         (when ,gowned
           (sprite-direct-test--kill-daemon ,gname ,gproc))))))

;;;; Process management tests

(ert-deftest sprite-direct-proc/socket-file-appears ()
  "Spawning a daemon creates its socket file within the timeout."
  (skip-unless (and (boundp 'server-socket-dir) server-socket-dir))
  (sprite-direct-test/with-fresh-daemon
    (should (file-exists-p
             (sprite-direct--socket-path sprite-direct-test--name)))))

(ert-deftest sprite-direct-proc/auth-file-appears ()
  "Authentication is available after spawning — via file or peer UID.
Emacs 29+ authenticates local sockets by peer UID rather than cookie files,
so this test accepts either: a readable auth file in `server-auth-dir' or
`server-socket-dir', OR a successful connection (peer-UID auth)."
  (skip-unless (and (boundp 'server-socket-dir) server-socket-dir))
  (sprite-direct-test/with-fresh-daemon
    (let ((in-auth-dir (and (boundp 'server-auth-dir) server-auth-dir
                            (file-exists-p
                             (expand-file-name sprite-direct-test--name
                                               server-auth-dir))))
          (in-sock-dir (file-exists-p
                        (expand-file-name sprite-direct-test--name
                                          server-socket-dir)))
          (can-ping (condition-case nil
                        (let ((sprite-direct-blocking-timeout 3.0))
                          (sprite-direct-call-and-read
                           sprite-direct-test--name 't))
                      (error nil))))
      (should (or in-auth-dir in-sock-dir can-ping)))))

(ert-deftest sprite-direct-proc/open-returns-conn ()
  "`sprite-direct-open' returns a live conn for a running daemon."
  (skip-unless (and (boundp 'server-socket-dir) server-socket-dir))
  (sprite-direct-test/with-fresh-daemon
    (let ((conn (sprite-direct-open sprite-direct-test--name)))
      (should (sprite-direct-conn-p conn))
      (should (equal sprite-direct-test--name (sprite-direct-conn-target conn))))))

(ert-deftest sprite-direct-proc/ping-returns-t ()
  "Evaluating `t' in the daemon returns t."
  (skip-unless (and (boundp 'server-socket-dir) server-socket-dir))
  (sprite-direct-test/with-fresh-daemon
    (let* ((conn (sprite-direct-open sprite-direct-test--name))
           (result (sprite-direct-eval-blocking conn 't sprite-direct-test--eval-timeout)))
      (should (eq t result)))))

(ert-deftest sprite-direct-proc/arithmetic-eval ()
  "Arithmetic expressions evaluate to the correct value."
  (skip-unless (and (boundp 'server-socket-dir) server-socket-dir))
  (sprite-direct-test/with-fresh-daemon
    (let* ((conn (sprite-direct-open sprite-direct-test--name))
           (result (sprite-direct-eval-blocking
                    conn '(+ 1 2 3 4) sprite-direct-test--eval-timeout)))
      (should (= 10 result)))))

(ert-deftest sprite-direct-proc/string-eval ()
  "String expressions round-trip correctly through the wire protocol."
  (skip-unless (and (boundp 'server-socket-dir) server-socket-dir))
  (sprite-direct-test/with-fresh-daemon
    (let* ((conn (sprite-direct-open sprite-direct-test--name))
           (result (sprite-direct-eval-blocking
                    conn '(concat "hello" " " "world")
                    sprite-direct-test--eval-timeout)))
      (should (equal "hello world" result)))))

(ert-deftest sprite-direct-proc/list-eval ()
  "List expressions round-trip correctly."
  (skip-unless (and (boundp 'server-socket-dir) server-socket-dir))
  (sprite-direct-test/with-fresh-daemon
    (let* ((conn (sprite-direct-open sprite-direct-test--name))
           (result (sprite-direct-eval-blocking
                    conn '(list 1 "two" 'three)
                    sprite-direct-test--eval-timeout)))
      (should (equal '(1 "two" three) result)))))

(ert-deftest sprite-direct-proc/eval-non-blocking-resolves ()
  "Non-blocking eval resolves to the correct value."
  (skip-unless (and (boundp 'server-socket-dir) server-socket-dir))
  (sprite-direct-test/with-fresh-daemon
    (let* ((conn (sprite-direct-open sprite-direct-test--name))
           (promise (sprite-direct-eval-non-blocking conn '(* 6 7))))
      (should (sprite-direct-promise-pending-p promise))
      (let ((result (sprite-direct-promise-wait promise sprite-direct-test--eval-timeout)))
        (should (sprite-direct-promise-resolved-p promise))
        (should (= 42 result))))))

(ert-deftest sprite-direct-proc/call-and-read-compatibility ()
  "`sprite-direct-call-and-read' evaluates a form by target name."
  (skip-unless (and (boundp 'server-socket-dir) server-socket-dir))
  (sprite-direct-test/with-fresh-daemon
    (let ((sprite-direct-blocking-timeout sprite-direct-test--eval-timeout))
      (should (= 7 (sprite-direct-call-and-read
                    sprite-direct-test--name '(+ 3 4)))))))

(ert-deftest sprite-direct-proc/daemon-shutdown ()
  "Evaluating `kill-emacs' shuts the daemon down cleanly."
  (skip-unless (and (boundp 'server-socket-dir) server-socket-dir))
  ;; This test manages its own daemon lifecycle without with-fresh-daemon so we
  ;; can verify the socket disappears after kill — with-fresh-daemon's cleanup
  ;; would obscure whether the socket was removed by kill-emacs or by us.
  (when (sprite-direct-test--socket-ready-p sprite-direct-test--name)
    (sprite-direct-test--kill-daemon sprite-direct-test--name nil)
    (sleep-for 0.5))
  (let ((proc (sprite-direct-test--spawn-daemon sprite-direct-test--name)))
    (unwind-protect
        (progn
          (should (sprite-direct-test--wait-for-socket sprite-direct-test--name))
          (condition-case nil
              (let ((sprite-direct-blocking-timeout 2.0))
                (sprite-direct-call-and-read sprite-direct-test--name '(kill-emacs 0)))
            (error nil))
          (sleep-for 1.0)
          (should-not (file-exists-p
                       (sprite-direct--socket-path sprite-direct-test--name))))
      (when (process-live-p proc) (delete-process proc))
      (when-let* ((sock (sprite-direct--socket-path sprite-direct-test--name))
                  ((file-exists-p sock)))
        (delete-file sock)))))

;;;; Buffer operation tests

(ert-deftest sprite-direct-buf/create-buffer ()
  "`get-buffer-create' in the sprite creates the buffer remotely."
  (sprite-direct-test/with-daemon conn
    (let ((buf (sprite-direct-test--unique-buf)))
      (unwind-protect
          (progn
            (sprite-direct-eval-blocking conn `(get-buffer-create ,buf)
                                         sprite-direct-test--eval-timeout)
            (should (sprite-direct-eval-blocking
                     conn `(buffer-live-p (get-buffer ,buf))
                     sprite-direct-test--eval-timeout)))
        (sprite-direct-eval-blocking conn `(when (get-buffer ,buf)
                                             (kill-buffer ,buf))
                                     sprite-direct-test--eval-timeout)))))

(ert-deftest sprite-direct-buf/insert-and-read-full ()
  "`sprite-direct-insert-into-buffer' and `sprite-direct-read-buffer' round-trip."
  (sprite-direct-test/with-daemon conn
    (let ((buf (sprite-direct-test--unique-buf)))
      (unwind-protect
          (progn
            (sprite-direct-eval-blocking conn `(get-buffer-create ,buf)
                                         sprite-direct-test--eval-timeout)
            (sprite-direct-insert-into-buffer conn buf "hello, world")
            (should (equal "hello, world"
                           (sprite-direct-read-buffer conn buf))))
        (sprite-direct-eval-blocking conn `(when (get-buffer ,buf)
                                             (kill-buffer ,buf))
                                     sprite-direct-test--eval-timeout)))))

(ert-deftest sprite-direct-buf/insert-appends-at-end ()
  "Multiple inserts without position accumulate at the end of the buffer."
  (sprite-direct-test/with-daemon conn
    (let ((buf (sprite-direct-test--unique-buf)))
      (unwind-protect
          (progn
            (sprite-direct-eval-blocking conn `(get-buffer-create ,buf)
                                         sprite-direct-test--eval-timeout)
            (sprite-direct-insert-into-buffer conn buf "foo")
            (sprite-direct-insert-into-buffer conn buf "bar")
            (should (equal "foobar"
                           (sprite-direct-read-buffer conn buf))))
        (sprite-direct-eval-blocking conn `(when (get-buffer ,buf)
                                             (kill-buffer ,buf))
                                     sprite-direct-test--eval-timeout)))))

(ert-deftest sprite-direct-buf/insert-at-position ()
  "Inserting at a given position puts text at the right point."
  (sprite-direct-test/with-daemon conn
    (let ((buf (sprite-direct-test--unique-buf)))
      (unwind-protect
          (progn
            (sprite-direct-eval-blocking conn `(get-buffer-create ,buf)
                                         sprite-direct-test--eval-timeout)
            (sprite-direct-insert-into-buffer conn buf "ac")
            (sprite-direct-insert-into-buffer conn buf "b" 2)
            (should (equal "abc"
                           (sprite-direct-read-buffer conn buf))))
        (sprite-direct-eval-blocking conn `(when (get-buffer ,buf)
                                             (kill-buffer ,buf))
                                     sprite-direct-test--eval-timeout)))))

(ert-deftest sprite-direct-buf/read-buffer-range ()
  "`sprite-direct-read-buffer' with explicit start/end returns the sub-range."
  (sprite-direct-test/with-daemon conn
    (let ((buf (sprite-direct-test--unique-buf)))
      (unwind-protect
          (progn
            (sprite-direct-eval-blocking conn `(get-buffer-create ,buf)
                                         sprite-direct-test--eval-timeout)
            (sprite-direct-insert-into-buffer conn buf "abcdef")
            (should (equal "bcd"
                           (sprite-direct-read-buffer conn buf 2 5))))
        (sprite-direct-eval-blocking conn `(when (get-buffer ,buf)
                                             (kill-buffer ,buf))
                                     sprite-direct-test--eval-timeout)))))

(ert-deftest sprite-direct-buf/buffer-local-variable ()
  "A buffer-local variable set via `with-current-sprite-direct-buffer' is readable."
  (sprite-direct-test/with-daemon conn
    (let ((buf (sprite-direct-test--unique-buf)))
      (unwind-protect
          (progn
            (sprite-direct-eval-blocking conn `(get-buffer-create ,buf)
                                         sprite-direct-test--eval-timeout)
            (with-current-sprite-direct-buffer (conn buf)
              (set (make-local-variable 'sprite-direct-test-local-var) 99))
            (let ((val (with-current-sprite-direct-buffer (conn buf)
                         sprite-direct-test-local-var)))
              (should (= 99 val))))
        (sprite-direct-eval-blocking conn `(when (get-buffer ,buf)
                                             (kill-buffer ,buf))
                                     sprite-direct-test--eval-timeout)))))

(ert-deftest sprite-direct-buf/with-current-buffer-macro-result ()
  "`with-current-sprite-direct-buffer' returns the value of the last form."
  (sprite-direct-test/with-daemon conn
    (let ((buf (sprite-direct-test--unique-buf)))
      (unwind-protect
          (progn
            (sprite-direct-eval-blocking conn `(get-buffer-create ,buf)
                                         sprite-direct-test--eval-timeout)
            (sprite-direct-insert-into-buffer conn buf "hello")
            (let ((result (with-current-sprite-direct-buffer (conn buf)
                            (point-max))))
              (should (= 6 result))))
        (sprite-direct-eval-blocking conn `(when (get-buffer ,buf)
                                             (kill-buffer ,buf))
                                     sprite-direct-test--eval-timeout)))))

(ert-deftest sprite-direct-buf/value-of-symbol ()
  "`sprite-direct-value-of-symbol' reads a global symbol from the daemon."
  (sprite-direct-test/with-daemon conn
    (sprite-direct-eval-blocking conn '(setq sprite-direct-test-global-sym 123)
                                 sprite-direct-test--eval-timeout)
    (should (= 123 (sprite-direct-value-of-symbol conn 'sprite-direct-test-global-sym)))))

(ert-deftest sprite-direct-buf/non-blocking-result-buffer ()
  "Non-blocking eval appends its result to the specified result buffer."
  (sprite-direct-test/with-daemon conn
    (let* ((result-buf (generate-new-buffer " *sdtest-results*")))
      (unwind-protect
          (progn
            (let ((promise (sprite-direct-eval-non-blocking
                            conn '(+ 100 200)
                            (buffer-name result-buf))))
              (sprite-direct-promise-wait promise sprite-direct-test--eval-timeout)
              (should (sprite-direct-promise-resolved-p promise))
              (should (= 300 (sprite-direct-promise-value promise)))
              (with-current-buffer result-buf
                (should (string-match-p "300" (buffer-string))))))
        (when (buffer-live-p result-buf)
          (kill-buffer result-buf))))))

(provide 'test-sprite-direct-integration)
;;; test-sprite-direct-integration.el ends here
