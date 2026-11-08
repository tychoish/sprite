;;; test-sprite-future.el --- ERT tests for sprite-future.el -*- lexical-binding: t; no-byte-compile: t; -*-

;; Run inside a live Emacs session:
;;   (ert "^sprite-future/")
;;
;; Batch run:
;;   emacs --batch -L ~/.emacs.d/external/sprite \
;;     -l ~/.emacs.d/external/sprite/test/test-sprite-future.el \
;;     --eval '(ert-run-tests-batch-and-exit "sprite-future/")'

;;; Commentary:
;;
;; Unit tests for sprite-future.el.  The transport layer (`sprite-direct-*'
;; and `make-process') is mocked throughout, matching test-sprite-direct.el's
;; approach -- no live daemons or real sockets/processes are required.
;;

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'sprite-future)

;;;; Predicates

(ert-deftest sprite-future/pending-p-true-when-pending ()
  (should (sprite-future-pending-p (sprite-future--make :state :pending))))

(ert-deftest sprite-future/pending-p-false-when-resolved ()
  (should-not (sprite-future-pending-p (sprite-future--make :state :resolved))))

(ert-deftest sprite-future/resolved-p-true-when-resolved ()
  (should (sprite-future-resolved-p (sprite-future--make :state :resolved))))

(ert-deftest sprite-future/resolved-p-false-when-pending ()
  (should-not (sprite-future-resolved-p (sprite-future--make :state :pending))))

(ert-deftest sprite-future/rejected-p-true-when-rejected ()
  (should (sprite-future-rejected-p (sprite-future--make :state :rejected))))

(ert-deftest sprite-future/rejected-p-false-when-resolved ()
  (should-not (sprite-future-rejected-p (sprite-future--make :state :resolved))))

;;;; Settling

(ert-deftest sprite-future/settle-transitions-pending-to-resolved ()
  (let ((future (sprite-future--make :state :pending)))
    (sprite-future--settle future :resolved 42)
    (should (sprite-future-resolved-p future))
    (should (= 42 (sprite-future-value future)))))

(ert-deftest sprite-future/settle-transitions-pending-to-rejected ()
  (let ((future (sprite-future--make :state :pending)))
    (sprite-future--settle future :rejected 'boom)
    (should (sprite-future-rejected-p future))
    (should (eq 'boom (sprite-future-value future)))))

(ert-deftest sprite-future/settle-is-noop-once-settled ()
  "Settling an already-settled future does not change its state or value."
  (let ((future (sprite-future--make :state :resolved :value 1)))
    (sprite-future--settle future :rejected 'ignored)
    (should (sprite-future-resolved-p future))
    (should (= 1 (sprite-future-value future)))))

(ert-deftest sprite-future/settle-runs-pending-callbacks ()
  (let ((future (sprite-future--make :state :pending))
        seen)
    (setf (sprite-future-callbacks future)
          (list (cons (lambda (v) (setq seen (cons :resolve v))) nil)))
    (sprite-future--settle future :resolved 7)
    (should (equal '(:resolve . 7) seen))))

(ert-deftest sprite-future/settle-runs-reject-callback-on-rejection ()
  (let ((future (sprite-future--make :state :pending))
        seen)
    (setf (sprite-future-callbacks future)
          (list (cons nil (lambda (v) (setq seen (cons :reject v))))))
    (sprite-future--settle future :rejected 'boom)
    (should (equal '(:reject . boom) seen))))

(ert-deftest sprite-future/settle-clears-callbacks-after-running ()
  (let ((future (sprite-future--make :state :pending)))
    (setf (sprite-future-callbacks future) (list (cons #'ignore #'ignore)))
    (sprite-future--settle future :resolved 1)
    (should (null (sprite-future-callbacks future)))))

;;;; Chaining: sprite-future-then

(ert-deftest sprite-future/then-runs-immediately-when-already-resolved ()
  (let* ((future (sprite-future--make :state :resolved :value 10))
         (chained (sprite-future-then future (lambda (v) (* v 2)))))
    (should (sprite-future-resolved-p chained))
    (should (= 20 (sprite-future-value chained)))))

(ert-deftest sprite-future/then-runs-on-reject-when-already-rejected ()
  (let* ((future (sprite-future--make :state :rejected :value 'boom))
         (chained (sprite-future-then future nil (lambda (e) (list :handled e)))))
    (should (sprite-future-resolved-p chained))
    (should (equal '(:handled boom) (sprite-future-value chained)))))

(ert-deftest sprite-future/then-passes-through-when-on-resolve-nil ()
  (let* ((future (sprite-future--make :state :resolved :value 5))
         (chained (sprite-future-then future nil)))
    (should (sprite-future-resolved-p chained))
    (should (= 5 (sprite-future-value chained)))))

(ert-deftest sprite-future/then-passes-through-rejection-when-on-reject-nil ()
  (let* ((future (sprite-future--make :state :rejected :value 'boom))
         (chained (sprite-future-then future (lambda (_) 'unused))))
    (should (sprite-future-rejected-p chained))
    (should (eq 'boom (sprite-future-value chained)))))

(ert-deftest sprite-future/then-rejects-chain-on-callback-error ()
  (let* ((future (sprite-future--make :state :resolved :value 1))
         (chained (sprite-future-then future (lambda (_) (error "boom")))))
    (should (sprite-future-rejected-p chained))))

(ert-deftest sprite-future/then-defers-until-source-settles ()
  (let* ((future (sprite-future--make :state :pending))
         (chained (sprite-future-then future (lambda (v) (1+ v)))))
    (should (sprite-future-pending-p chained))
    (sprite-future--settle future :resolved 41)
    (should (sprite-future-resolved-p chained))
    (should (= 42 (sprite-future-value chained)))))

;;;; sprite-future-wait

(ert-deftest sprite-future/wait-returns-immediately-when-already-resolved ()
  (let ((future (sprite-future--make :state :resolved :value 99)))
    (should (= 99 (sprite-future-wait future :timeout 1)))))

(ert-deftest sprite-future/wait-returns-nil-when-already-rejected ()
  (let ((future (sprite-future--make :state :rejected :value nil)))
    (should (null (sprite-future-wait future :timeout 1)))))

(ert-deftest sprite-future/wait-times-out-when-still-pending ()
  "`sprite-future-wait' gives up and returns nil after TIMEOUT with no proc."
  (let ((future (sprite-future--make :state :pending :backend-handle nil)))
    (should (null (sprite-future-wait future :timeout 0.05)))
    (should (sprite-future-pending-p future))))

(ert-deftest sprite-future/wait-runs-timer-after-process-exits ()
  (let* ((proc (make-process :name "sprite-future-exited-test"
                             :command '("true") :sentinel #'ignore))
         (future (sprite-future--make :state :pending :backend-handle proc))
         timer)
    (unwind-protect
        (progn
          (while (process-live-p proc) (accept-process-output proc 0.1))
          (setq timer (run-at-time 0.01 nil #'sprite-future--settle future :resolved 42))
          (should (= 42 (sprite-future-wait future :timeout 1)))
          (should (sprite-future-resolved-p future)))
      (when timer (cancel-timer timer))
      (when (process-live-p proc) (delete-process proc)))))

(ert-deftest sprite-future/wait-drives-delayed-settlement-after-process-exit ()
  (let ((future (sprite-future--make :state :pending :backend-handle 'dead-process))
        (calls 0))
    (cl-letf (((symbol-function 'sprite-future--handle-process) (lambda (_) 'dead-process))
              ((symbol-function 'process-live-p) (lambda (_) nil))
              ((symbol-function 'accept-process-output)
               (lambda (&rest _)
                 (cl-incf calls)
                 (sprite-future--settle future :resolved 42))))
      (should (= 42 (sprite-future-wait future :timeout 1)))
      (should (= 1 calls)))))

;;;; Backend dispatch: sprite-future-eval

(ert-deftest sprite-future/eval-dispatches-to-emacsclient-by-default ()
  (let ((sprite-communication-backend 'emacsclient)
        called)
    (cl-letf (((symbol-function 'sprite-future--spawn-emacsclient)
               (lambda (&rest _) (setq called t)))
              ((symbol-function 'sprite-future--eval-direct)
               (lambda (&rest _) (error "should not be called"))))
      (sprite-future-eval "work.0.render" '(+ 1 2))
      (should called))))

(ert-deftest sprite-future/eval-dispatches-to-direct-when-configured ()
  (let ((sprite-communication-backend 'direct)
        called)
    (cl-letf (((symbol-function 'sprite-future--eval-direct)
               (lambda (&rest _) (setq called t)))
              ((symbol-function 'sprite-future--spawn-emacsclient)
               (lambda (&rest _) (error "should not be called"))))
      (sprite-future-eval "work.0.render" '(+ 1 2))
      (should called))))

(ert-deftest sprite-future/eval-returns-a-pending-future ()
  (let ((sprite-communication-backend 'emacsclient))
    (cl-letf (((symbol-function 'sprite-future--spawn-emacsclient) #'ignore))
      (let ((future (sprite-future-eval "work.0.render" '(+ 1 2))))
        (should (sprite-future-p future))
        (should (equal "work.0.render" (sprite-future-target future)))))))

(ert-deftest sprite-future/eval-logs-dispatch-in-target-buffer ()
  (let* ((sprite-communication-backend 'emacsclient)
         (name "future-test-log-target")
         (buffer-name (sprite--log-buffer-name name)))
    (unwind-protect
        (cl-letf (((symbol-function 'sprite-future--spawn-emacsclient) #'ignore))
          (sprite-future-eval name '(+ 1 2) :log t)
          (with-current-buffer buffer-name
            (should (string-match-p (concat "sent .*: " (regexp-quote "(+ 1 2)"))
                                    (buffer-string)))))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest sprite-future/eval-logs-settlement-once-for-chains ()
  (let ((sprite-communication-backend 'emacsclient)
        entries)
    (cl-letf (((symbol-function 'sprite--log)
               (lambda (name direction content)
                 (push (list name direction content) entries)))
              ((symbol-function 'sprite-future--spawn-emacsclient) #'ignore))
      (let* ((future (sprite-future-eval "test" '(+ 1 2) :log t))
             (chain (sprite-future-then future (lambda (value) (1+ value)))))
        (sprite-future--settle future :resolved 3)
        (sprite-future--settle future :rejected 'ignored)
        (should (= 4 (sprite-future-value chain)))
        (should (equal (nreverse entries)
                       '(("test" sent "(+ 1 2)") ("test" received "3"))))))))

(ert-deftest sprite-future/eval-logs-rejection-and-cancellation ()
  (let ((sprite-communication-backend 'emacsclient)
        entries)
    (cl-letf (((symbol-function 'sprite--log)
               (lambda (_name direction content) (push (list direction content) entries)))
              ((symbol-function 'sprite-future--spawn-emacsclient) #'ignore))
      (let ((failed (sprite-future-eval "test" '(fail) :log t))
            (canceled (sprite-future-eval "test" '(cancel) :log t)))
        (sprite-future--settle failed :rejected 'boom)
        (sprite-future-cancel canceled 'requested)
        (should (equal (nreverse entries)
                       '((sent "(fail)") (sent "(cancel)")
                         (error "boom") (error "(:canceled . requested)"))))))))

(ert-deftest sprite-future/eval-logs-immediate-direct-connection-failure ()
  (let ((sprite-communication-backend 'direct)
        entries)
    (cl-letf (((symbol-function 'sprite--log)
               (lambda (_name direction content) (push (list direction content) entries)))
              ((symbol-function 'sprite--direct-target) #'identity)
              ((symbol-function 'sprite-direct-open) (lambda (_) (error "offline"))))
      (let ((future (sprite-future-eval "test" '(work) :log t)))
        (should (sprite-future-rejected-p future))
        (should-not (sprite-future-backend-handle future))
        (should (equal (nreverse entries) '((sent "(work)") (error "nil")))))
      (setq entries nil)
      (should (sprite-future-rejected-p
               (sprite-future-eval "test" '(work))))
      (should-not entries))))

(ert-deftest sprite-future/direct-socket-open-failure-settles-and-logs ()
  (let ((sprite-communication-backend 'direct) entries)
    (cl-letf (((symbol-function 'sprite--direct-target) #'identity)
              ((symbol-function 'sprite-direct-open)
               (lambda (target) (sprite-direct--conn-make :target target :plist nil)))
              ((symbol-function 'sprite-direct--open) (lambda (_) (error "offline")))
              ((symbol-function 'sprite--log)
               (lambda (_ direction content) (push (list direction content) entries))))
      (dolist (logging '(t nil))
        (setq entries nil)
        (let ((future (sprite-future-eval "test" '(work) :log logging)))
          (should-not (sprite-future-wait future :timeout 1))
          (should (sprite-future-rejected-p future))
          (should (equal (nreverse entries)
                         (when logging '((sent "(work)") (error "nil"))))))))))

(ert-deftest sprite-future/cancel-preserves-reason-when-sentinel-runs ()
  (let ((future (sprite-future--make :target "test" :state :pending
                                     :remote-dispatch t :log t))
        entries proc)
    (unwind-protect
        (cl-letf (((symbol-function 'sprite--log)
                   (lambda (_name direction content)
                     (push (list direction content) entries))))
          (setq proc (make-process :name "sprite-future-cancel-test"
                                   :command '("cat")
                                   :sentinel (lambda (_proc _event)
                                               (sprite-future--settle future :rejected nil))))
          (setf (sprite-future-backend-handle future) proc)
          (should (sprite-future-cancel future 'requested))
          (should (equal '(:canceled . requested) (sprite-future-value future)))
          (should (equal '((error "(:canceled . requested)")) entries)))
      (when (and proc (process-live-p proc))
        (delete-process proc)))))

(ert-deftest sprite-future/cancel-callback-observes-dead-process ()
  (let ((future (sprite-future--make :state :pending)) proc observed)
    (unwind-protect
        (progn
          (setq proc (make-process :name "sprite-future-cancel-callback"
                                   :command '("cat") :sentinel #'ignore))
          (setf (sprite-future-backend-handle future) proc)
          (sprite-future-then future nil
                              (lambda (_) (setq observed (if (process-live-p proc) :live :dead))))
          (sprite-future-cancel future)
          (should (eq :dead observed)))
      (when (and proc (process-live-p proc)) (delete-process proc)))))

(ert-deftest sprite-future/eval-default-suppresses-dispatch-and-outcome ()
  (let ((sprite-communication-backend 'emacsclient)
        entries)
    (cl-letf (((symbol-function 'sprite--log) (lambda (&rest args) (push args entries)))
              ((symbol-function 'sprite-future--spawn-emacsclient) #'ignore))
      (let ((future (sprite-future-eval "test" '(work))))
        (sprite-future--settle future :rejected 'boom)
        (should-not entries)))))

(ert-deftest sprite-future/eval-logs-and-resignals-transport-errors ()
  (let ((sprite-communication-backend 'emacsclient)
        entries)
    (cl-letf (((symbol-function 'sprite--log)
               (lambda (_name direction content)
                 (push (list direction content) entries)))
              ((symbol-function 'sprite-future--spawn-emacsclient)
               (lambda (&rest _) (error "transport failed"))))
      (should-error (sprite-future-eval "test" '(work) :log t))
      (should (equal (nreverse entries)
                     '((sent "(work)") (error "transport failed"))))
      (setq entries nil)
      (should-error (sprite-future-eval "test" '(work)))
      (should-not entries))))

(ert-deftest sprite-future/with-sprite-async-returns-original-and-runs-callbacks ()
  (let ((sprite-communication-backend 'emacsclient)
        dispatched seen (name-count 0))
    (cl-letf (((symbol-function 'sprite--log) #'ignore)
              ((symbol-function 'sprite-future--spawn-emacsclient)
               (lambda (name form future) (setq dispatched (list name form future)))))
      (let ((future (with-sprite-async (progn (cl-incf name-count) "test")
                        (+ 1 2)
                      :on-resolve (lambda (value) (setq seen (list :resolved value)))
                      :on-reject (lambda (value) (setq seen (list :rejected value))))))
        (should (sprite-future-pending-p future))
        (should (= 1 name-count))
        (should (equal (list "test" '(+ 1 2) future) dispatched))
        (sprite-future--settle future :resolved 3)
        (should (equal '(:resolved 3) seen)))
      (let ((future (with-sprite-async "test" (fail)
                      :on-reject (lambda (value) (setq seen (list :rejected value))))))
        (sprite-future--settle future :rejected 'boom)
        (should (equal '(:rejected boom) seen))))))

(ert-deftest sprite-future/with-sprite-async-default-suppresses-outcomes ()
  (let ((sprite-communication-backend 'emacsclient)
        entries)
    (cl-letf (((symbol-function 'sprite--log) (lambda (&rest args) (push args entries)))
              ((symbol-function 'sprite-future--spawn-emacsclient) #'ignore))
      (let ((future (with-sprite-async "test" (work))))
        (sprite-future--settle future :resolved nil)
        (should-not entries)))))

(ert-deftest sprite-future/with-sprite-async-opt-in-logs-outcome ()
  (let ((sprite-communication-backend 'emacsclient) entries (logging t))
    (cl-letf (((symbol-function 'sprite--log)
               (lambda (_name direction content) (push (list direction content) entries)))
              ((symbol-function 'sprite-future--spawn-emacsclient) #'ignore))
      (let ((future (with-sprite-async "test" (work) :log logging)))
        (sprite-future--settle future :resolved nil)
        (should (equal (nreverse entries) '((sent "(work)") (received "nil"))))))))

(ert-deftest sprite-future/with-sprite-async-reports-callback-errors ()
  (let ((sprite-communication-backend 'emacsclient) warnings)
    (cl-letf (((symbol-function 'sprite-future--spawn-emacsclient) #'ignore)
              ((symbol-function 'display-warning)
               (lambda (&rest args) (push args warnings))))
      (let ((future (with-sprite-async "test" (work)
                      :on-resolve (lambda (_) (error "callback failed")))))
        (sprite-future--settle future :resolved 3)
        (should (sprite-future-resolved-p future))
        (should (= 1 (length warnings)))
        (should (string-match-p "callback failed" (format "%S" warnings)))))))

(ert-deftest sprite-future/with-sprite-async-runs-callback-for-immediate-failure ()
  (let ((sprite-communication-backend 'direct) seen)
    (cl-letf (((symbol-function 'sprite--direct-target) #'identity)
              ((symbol-function 'sprite-direct-open) (lambda (_) (error "offline"))))
      (let ((future (with-sprite-async "test" (work)
                      :on-reject (lambda (value) (setq seen (list :rejected value))))))
        (should (sprite-future-rejected-p future))
        (should (equal '(:rejected nil) seen))))))

;;;; Direct backend: sprite-future--eval-direct

(ert-deftest sprite-future/eval-direct-settles-via-promise-then ()
  "The direct backend settles FUTURE from the callback registered on the promise."
  (let (then-callback)
    (cl-letf (((symbol-function 'sprite-direct-open) (lambda (_) 'fake-conn))
              ((symbol-function 'sprite-direct-eval-non-blocking) (lambda (_ _form) 'fake-promise))
              ((symbol-function 'sprite-direct-promise-then)
               (lambda (_promise cb) (setq then-callback cb))))
      (let ((future (sprite-future--make :target "work.0.render" :state :pending)))
        (sprite-future--eval-direct future '(+ 1 2))
        (should (sprite-future-pending-p future))
        (funcall then-callback :resolved 3)
        (should (sprite-future-resolved-p future))
        (should (= 3 (sprite-future-value future)))))))

(ert-deftest sprite-future/eval-direct-settles-rejected-via-promise-then ()
  (let (then-callback)
    (cl-letf (((symbol-function 'sprite-direct-open) (lambda (_) 'fake-conn))
              ((symbol-function 'sprite-direct-eval-non-blocking) (lambda (_ _form) 'fake-promise))
              ((symbol-function 'sprite-direct-promise-then)
               (lambda (_promise cb) (setq then-callback cb))))
      (let ((future (sprite-future--make :target "work.0.render" :state :pending)))
        (sprite-future--eval-direct future '(+ 1 2))
        (funcall then-callback :rejected nil)
        (should (sprite-future-rejected-p future))))))

(ert-deftest sprite-future/eval-direct-rejects-immediately-when-open-fails ()
  "A connection failure (e.g. `user-error' from `sprite--direct-target') rejects FUTURE
without waiting on any promise."
  (cl-letf (((symbol-function 'sprite-direct-open) (lambda (_) (user-error "no auth key"))))
    (let ((future (sprite-future--make :target "work.0.render" :state :pending)))
      (sprite-future--eval-direct future '(+ 1 2))
      (should (sprite-future-rejected-p future)))))

;;;; emacsclient backend: sprite-future--spawn-emacsclient / sprite-future--settle-from-process

(ert-deftest sprite-future/spawn-emacsclient-future-invokes-make-process ()
  "`sprite-future--spawn-emacsclient' passes the right emacsclient command."
  (let (captured)
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest plist) (setq captured plist) 'fake-proc)))
      (let ((future (sprite-future--make :target "work.0.render" :state :pending)))
        (sprite-future--spawn-emacsclient "work.0.render" '(+ 1 2) future)
        (should (equal '("emacsclient" "--socket-name" "work.0.render" "--eval" "(+ 1 2)")
                       (plist-get captured :command)))
        (should (eq 'fake-proc (sprite-future-backend-handle future)))))))

(ert-deftest sprite-future/settle-from-process-resolves-on-exit-zero ()
  "Exit code 0 resolves FUTURE with the process buffer's value, read as Lisp."
  (let ((future (sprite-future--make :state :pending))
        (buf (generate-new-buffer " *sprite-future-test*")))
    (unwind-protect
        (progn
          (with-current-buffer buf (insert "42"))
          (cl-letf (((symbol-function 'process-exit-status) (lambda (_) 0))
                    ((symbol-function 'process-buffer) (lambda (_) buf)))
            (sprite-future--settle-from-process future 'fake-proc))
          (should (sprite-future-resolved-p future))
          (should (= 42 (sprite-future-value future))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest sprite-future/settle-from-process-rejects-on-nonzero-exit ()
  (let ((future (sprite-future--make :state :pending)))
    (cl-letf (((symbol-function 'process-exit-status) (lambda (_) 1))
              ((symbol-function 'process-buffer) (lambda (_) nil)))
      (sprite-future--settle-from-process future 'fake-proc))
    (should (sprite-future-rejected-p future))))

(ert-deftest sprite-future/settle-from-process-kills-the-buffer ()
  (let ((future (sprite-future--make :state :pending))
        (buf (generate-new-buffer " *sprite-future-test-kill*")))
    (cl-letf (((symbol-function 'process-exit-status) (lambda (_) 0))
              ((symbol-function 'process-buffer) (lambda (_) buf)))
      (sprite-future--settle-from-process future 'fake-proc))
    (should-not (buffer-live-p buf))))

;;;; Async/await

(ert-deftest sprite-future/async-defun-returns-a-future-immediately ()
  "Calling a `sprite-future-async-defun' returns a `sprite-future' without blocking."
  (sprite-future-async-defun sprite-future-test--noop-workflow ()
    1)
  (should (sprite-future-p (sprite-future-test--noop-workflow))))

(ert-deftest sprite-future/async-defun-resolves-with-return-value-no-await ()
  "A workflow with no `sprite-future-await' resolves immediately with its return value."
  (sprite-future-async-defun sprite-future-test--const-workflow ()
    42)
  (should (= 42 (sprite-future-wait (sprite-future-test--const-workflow) :timeout 1))))

(ert-deftest sprite-future/async-await-resumes-with-resolved-value ()
  "`sprite-future-await' resumes with the value of an already-resolved future."
  (sprite-future-async-defun sprite-future-test--await-workflow (f)
    (1+ (sprite-future-await f)))
  (let ((inner (sprite-future--make :state :resolved :value 9)))
    (should (= 10 (sprite-future-wait (sprite-future-test--await-workflow inner) :timeout 1)))))

(ert-deftest sprite-future/async-await-multistep ()
  "Sequential `sprite-future-await' calls thread values through the workflow in order."
  (sprite-future-async-defun sprite-future-test--multistep-workflow (a b)
    (let ((x (sprite-future-await a)))
      (+ x (sprite-future-await b))))
  (let ((fa (sprite-future--make :state :resolved :value 10))
        (fb (sprite-future--make :state :resolved :value 32)))
    (should (= 42 (sprite-future-wait
                   (sprite-future-test--multistep-workflow fa fb) :timeout 1)))))

(ert-deftest sprite-future/async-await-suspends-until-pending-future-settles ()
  "`sprite-future-await' on a still-pending future suspends the workflow without polling."
  (sprite-future-async-defun sprite-future-test--suspend-workflow (f)
    (sprite-future-await f))
  (let* ((inner (sprite-future--make :state :pending))
         (outer (sprite-future-test--suspend-workflow inner)))
    (should (sprite-future-pending-p outer))
    (sprite-future--settle inner :resolved 'done)
    (should (sprite-future-resolved-p outer))
    (should (eq 'done (sprite-future-value outer)))))

(ert-deftest sprite-future/async-await-rejection-propagates-uncaught ()
  "An uncaught rejection from `sprite-future-await' rejects the workflow's own future."
  (sprite-future-async-defun sprite-future-test--reject-workflow (f)
    (sprite-future-await f))
  (let* ((inner (sprite-future--make :state :rejected :value 'boom))
         (outer (sprite-future-test--reject-workflow inner)))
    (should (sprite-future-rejected-p outer))))

(ert-deftest sprite-future/async-await-rejection-caught-by-condition-case ()
  "A workflow body can catch a rejected `sprite-future-await' with an ordinary `condition-case'."
  (sprite-future-async-defun sprite-future-test--catch-workflow (f)
    (condition-case err
        (sprite-future-await f)
      (sprite-future-rejected (list :caught (cadr err)))))
  (let* ((inner (sprite-future--make :state :rejected :value 'boom))
         (outer (sprite-future-test--catch-workflow inner)))
    (should (sprite-future-resolved-p outer))
    (should (equal '(:caught boom) (sprite-future-value outer)))))

(ert-deftest sprite-future/async-defun-interactive-preserves-commandp ()
  "sprite-future-async-defun preserves interactive declaration making commandp true."
  (sprite-future-async-defun sprite-future-test--interactive-cmd (&optional _force)
    "Interactive test command."
    (interactive "P")
    42)
  (should (commandp 'sprite-future-test--interactive-cmd)))

(provide 'test-sprite-future)
;;; test-sprite-future.el ends here
