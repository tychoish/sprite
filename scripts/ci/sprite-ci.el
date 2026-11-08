;;; sprite-ci.el --- CI orchestration for the sprite-direct clients  -*- lexical-binding: t; -*-

;; Run with the Emacs under test, from anywhere:
;;
;;   emacs --batch -l scripts/ci/sprite-ci.el -f sprite-ci-main test python
;;   emacs --batch -l scripts/ci/sprite-ci.el -f sprite-ci-main bench
;;
;; Each run spawns one disposable daemon (the same Emacs binary that is
;; running this script), exports its socket to the client suites, runs
;; them, and tears the daemon down.  Only built-in libraries are used.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defconst sprite-ci-root
  (file-name-as-directory
   (expand-file-name "../.." (file-name-directory
                              (or load-file-name buffer-file-name))))
  "Repository root.")

(defconst sprite-ci-daemon-name "ci.0.sprite")

(defconst sprite-ci-test-steps
  `((python
     :setup (("python" "-m" "venv" "python/.venv")
             ("python/.venv/bin/pip" "install" "-e" "./python" "pytest"))
     :run (("python/.venv/bin/pytest" "-q" "python")))
    (javascript
     :run (("npm" "--prefix" "js" "test")))
    (go
     :run (("go" "build" "./...")
           ("go" "vet" "./...")
           ("go" "test" "./...")
           ("go" "run" "./cmd/sprite" "call" ,sprite-ci-daemon-name "+" "--args" "[1,2]")
           ("go" "run" "./cmd/sprite" "eval" ,sprite-ci-daemon-name "(+ 3 4)")))
    (rust
     :run (("cargo" "test" "--manifest-path" "rust/Cargo.toml" "--features" "async"))))
  "Per-client commands: `:setup' runs before the daemon, `:run' against it.")

(defconst sprite-ci-bench-steps
  '(("Go" (("go" "test" "./go/protocol/..." "-run" "^$" "-bench" "." "-benchmem")))
    ("Python" (("python" "-m" "venv" "python/.venv")
               ("python/.venv/bin/pip" "install" "-e" "./python[bench]")
               ("python/.venv/bin/pytest" "python/tests/test_bench.py"
                "--benchmark-only" "-v")))
    ("JavaScript" (("node" "js/bench/bench.js")))
    ("Rust" (("cargo" "bench" "--manifest-path" "rust/Cargo.toml"
              "--bench" "eval_bench"))))
  "Benchmarks as (TITLE COMMANDS); failures are reported but never fatal.")

(defun sprite-ci--log (fmt &rest args)
  (message "[sprite-ci] %s" (apply #'format fmt args)))

(defun sprite-ci--run (command &optional capture)
  "Run COMMAND (a list) in the repo root, streaming its output.
Return the exit status.  When CAPTURE is a buffer, also collect output there."
  (sprite-ci--log "$ %s" (string-join command " "))
  (let* ((default-directory sprite-ci-root)
         (proc (make-process
                :name (car command)
                :command (cons (if (string-search "/" (car command))
                                   (expand-file-name (car command) sprite-ci-root)
                                 (car command))
                               (cdr command)) :connection-type 'pipe
                :noquery t :stderr nil
                :filter (lambda (_p s)
                          (send-string-to-terminal s)
                          (when capture
                            (with-current-buffer capture (insert s)))))))
    (while (process-live-p proc)
      (accept-process-output proc 0.2))
    (process-exit-status proc)))

(defun sprite-ci--run-all (commands)
  "Run COMMANDS in order, signalling an error on the first failure."
  (dolist (command commands)
    (unless (zerop (sprite-ci--run command))
      (error "Command failed: %s" (string-join command " ")))))

(defun sprite-ci--start-daemon (runtime)
  "Start a daemon rooted in RUNTIME; return (PROCESS . SOCKET)."
  (let* ((process-environment
          (append (list (concat "XDG_RUNTIME_DIR=" runtime)) process-environment))
         (socket (expand-file-name (concat "emacs/" sprite-ci-daemon-name) runtime))
         (proc (make-process
                :name "sprite-ci-daemon" :noquery t :connection-type 'pipe
                :command (list (expand-file-name invocation-name invocation-directory)
                               (concat "--fg-daemon=" sprite-ci-daemon-name)
                               "--no-init-file" "--no-site-file"
                               "--eval" (format "(load-file %S)"
                                                (expand-file-name "sprite-async.el"
                                                                  sprite-ci-root)))
                :filter #'ignore)))
    (cl-loop repeat 60
             until (file-exists-p socket)
             unless (process-live-p proc) do (error "Emacs daemon exited early")
             do (accept-process-output proc 0.5))
    (unless (file-exists-p socket)
      (error "Daemon socket never appeared: %s" socket))
    (cons proc socket)))

(defmacro sprite-ci--with-daemon (&rest body)
  "Run BODY with a daemon up and the SPRITE_* environment pointing at it."
  (declare (indent 0))
  `(let* ((runtime (make-temp-file "sprite-ci." t))
          (daemon (sprite-ci--start-daemon runtime))
          (process-environment
           (append (list (concat "XDG_RUNTIME_DIR=" runtime)
                         (concat "SPRITE_SOCKET_DIR=" (expand-file-name "emacs" runtime))
                         (concat "SPRITE_TEST_SOCKET=" (cdr daemon)))
                   process-environment)))
     (unwind-protect (progn ,@body)
       (when (process-live-p (car daemon)) (kill-process (car daemon)))
       (delete-directory runtime t))))

(defun sprite-ci-test (client)
  "Run the CLIENT suite (a symbol) against a disposable daemon."
  (let ((steps (or (alist-get client sprite-ci-test-steps)
                   (user-error "Unknown client: %s" client))))
    (sprite-ci--log "Emacs %s, client %s" emacs-version client)
    (sprite-ci--run-all (plist-get steps :setup))
    (sprite-ci--with-daemon
      (sprite-ci--run-all (plist-get steps :run)))))

(defun sprite-ci-bench ()
  "Run every benchmark; append results to $GITHUB_STEP_SUMMARY when set."
  (let ((summary (getenv "GITHUB_STEP_SUMMARY")))
    (sprite-ci--with-daemon
      (pcase-dolist (`(,title ,commands) sprite-ci-bench-steps)
        (with-temp-buffer
          (let ((status 0))
            (dolist (command commands)
              (when (zerop status)
                (setq status (sprite-ci--run command (current-buffer)))))
            (unless (zerop status)
              (sprite-ci--log "benchmark %s failed (non-fatal)" title))
            (when summary
              (write-region (format "## %s\n```\n%s```\n" title (buffer-string))
                            nil summary t 'silent))))))))

(defun sprite-ci-main ()
  "Entry point: consume the remaining command-line arguments."
  (let ((args (cl-remove "--" command-line-args-left :test #'equal)))
    (setq command-line-args-left nil)
    (condition-case err
        (pcase args
          (`("test" ,client) (sprite-ci-test (intern client)))
          (`("bench") (sprite-ci-bench))
          (_ (user-error "Usage: test <python|javascript|go|rust> | bench")))
      (error (message "sprite-ci: %s" (error-message-string err))
             (kill-emacs 1)))))

(provide 'sprite-ci)
;;; sprite-ci.el ends here
