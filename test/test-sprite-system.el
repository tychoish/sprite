;;; test-sprite-system.el --- ERT tests for sprite-system.el -*- lexical-binding: t; no-byte-compile: t; -*-

;; Run inside a live Emacs session:
;;   (ert "^sprite-system/")
;;
;; Batch run:
;;   emacs --batch -L ~/.emacs.d/external/sprite \
;;     -l ~/.emacs.d/external/sprite/test/test-sprite-system.el \
;;     --eval '(ert-run-tests-batch-and-exit "sprite-system/")'

;;; Commentary:
;;
;; Unit tests for sprite-system.el.  DBus functions and system-type are
;; mocked via cl-letf so no live DBus connection or real idle timers are
;; required.  The with-clean-state macro isolates all mutable var state.
;;

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'sprite-system)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Test helpers

(defmacro sprite-system-test/with-clean-state (&rest body)
  "Run BODY with isolated sprite-system hook and timer state.
Cancels any timer created during BODY on exit."
  (declare (indent 0))
  `(let ((sprite-system-idle-hook nil)
         (sprite-system--idle-timer nil)
         (sprite-system--logind-signal nil)
         (sprite-system--dbus-signals nil))
     (unwind-protect
         (progn ,@body)
       (when (timerp sprite-system--idle-timer)
         (cancel-timer sprite-system--idle-timer)))))

(defmacro sprite-system-test/capture-messages (&rest body)
  "Execute BODY and return the list of strings passed to `message' in order."
  (declare (indent 0))
  (let ((msgs (gensym "msgs")))
    `(let (,msgs)
       (cl-letf (((symbol-function 'message)
                  (lambda (fmt &rest args)
                    (push (apply #'format fmt args) ,msgs))))
         ,@body)
       (nreverse ,msgs))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; sprite-system-start/stop-idle-timer

(ert-deftest sprite-system/start-idle-timer-creates-timer ()
  "`sprite-system-start-idle-timer' stores a live timer in the state variable."
  (sprite-system-test/with-clean-state
    (sprite-system-start-idle-timer)
    (should (timerp sprite-system--idle-timer))))

(ert-deftest sprite-system/stop-idle-timer-cancels-and-nils ()
  "`sprite-system-stop-idle-timer' cancels the timer and sets the var to nil."
  (sprite-system-test/with-clean-state
    (sprite-system-start-idle-timer)
    (sprite-system-stop-idle-timer)
    (should (null sprite-system--idle-timer))))

(ert-deftest sprite-system/stop-idle-timer-noop-when-nil ()
  "`sprite-system-stop-idle-timer' does not error when timer is already nil."
  (sprite-system-test/with-clean-state
    (sprite-system-stop-idle-timer)))

(ert-deftest sprite-system/start-idle-timer-replaces-existing ()
  "Calling start twice replaces the first timer with a new one."
  (sprite-system-test/with-clean-state
    (sprite-system-start-idle-timer)
    (let ((first sprite-system--idle-timer))
      (sprite-system-start-idle-timer)
      (should (timerp sprite-system--idle-timer))
      (should-not (eq first sprite-system--idle-timer)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; sprite-system-sync-idle-timer

(ert-deftest sprite-system/sync-starts-timer-when-hook-nonempty ()
  "`sprite-system-sync-idle-timer' starts the timer when the hook has members."
  (sprite-system-test/with-clean-state
    (cl-letf (((symbol-function 'message) #'ignore))
      (add-hook 'sprite-system-idle-hook #'ignore)
      (sprite-system-sync-idle-timer)
      (should (timerp sprite-system--idle-timer)))))

(ert-deftest sprite-system/sync-stops-timer-when-hook-empty ()
  "`sprite-system-sync-idle-timer' stops the timer when the hook is empty."
  (sprite-system-test/with-clean-state
    (cl-letf (((symbol-function 'message) #'ignore))
      (sprite-system-start-idle-timer)
      (sprite-system-sync-idle-timer)
      (should (null sprite-system--idle-timer)))))

(ert-deftest sprite-system/sync-does-not-restart-running-timer ()
  "`sprite-system-sync-idle-timer' leaves an already-running timer untouched."
  (sprite-system-test/with-clean-state
    (cl-letf (((symbol-function 'message) #'ignore))
      (add-hook 'sprite-system-idle-hook #'ignore)
      (sprite-system-start-idle-timer)
      (let ((first sprite-system--idle-timer))
        (sprite-system-sync-idle-timer)
        (should (eq first sprite-system--idle-timer))))))

(ert-deftest sprite-system/sync-noop-when-hook-empty-and-timer-nil ()
  "`sprite-system-sync-idle-timer' does not error when hook empty and timer nil."
  (sprite-system-test/with-clean-state
    (cl-letf (((symbol-function 'message) #'ignore))
      (sprite-system-sync-idle-timer))))

(ert-deftest sprite-system/sync-logs-running-state ()
  "`sprite-system-sync-idle-timer' logs \"running\" when the timer is active."
  (sprite-system-test/with-clean-state
    (add-hook 'sprite-system-idle-hook #'ignore)
    (let ((msgs (sprite-system-test/capture-messages
                  (sprite-system-sync-idle-timer))))
      (should (= 1 (length msgs)))
      (should (string-match-p "running" (car msgs))))))

(ert-deftest sprite-system/sync-logs-stopped-state ()
  "`sprite-system-sync-idle-timer' logs \"stopped\" when the hook is empty."
  (sprite-system-test/with-clean-state
    (let ((msgs (sprite-system-test/capture-messages
                  (sprite-system-sync-idle-timer))))
      (should (= 1 (length msgs)))
      (should (string-match-p "stopped" (car msgs))))))

(ert-deftest sprite-system/sync-logs-registered-op-count ()
  "`sprite-system-sync-idle-timer' includes the count of registered ops."
  (sprite-system-test/with-clean-state
    (add-hook 'sprite-system-idle-hook #'ignore)
    (add-hook 'sprite-system-idle-hook #'identity)
    (let ((msgs (sprite-system-test/capture-messages
                  (sprite-system-sync-idle-timer))))
      (should (string-match-p "2" (car msgs))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; sprite-system-add-on-idle

(ert-deftest sprite-system/add-on-idle-adds-fn-to-hook ()
  "`sprite-system-add-on-idle' adds fn to `sprite-system-idle-hook'."
  (sprite-system-test/with-clean-state
    (cl-letf (((symbol-function 'message) #'ignore))
      (sprite-system-add-on-idle #'ignore)
      (should (memq #'ignore sprite-system-idle-hook)))))

(ert-deftest sprite-system/add-on-idle-starts-timer ()
  "`sprite-system-add-on-idle' starts the idle timer."
  (sprite-system-test/with-clean-state
    (cl-letf (((symbol-function 'message) #'ignore))
      (sprite-system-add-on-idle #'ignore)
      (should (timerp sprite-system--idle-timer)))))

(ert-deftest sprite-system/add-on-idle-logs-registration ()
  "`sprite-system-add-on-idle' logs \"registered\" with the function name."
  (sprite-system-test/with-clean-state
    (let ((msgs (sprite-system-test/capture-messages
                  (sprite-system-add-on-idle #'ignore))))
      (should (string-match-p "registered" (car msgs)))
      (should (string-match-p "ignore" (car msgs))))))

(ert-deftest sprite-system/add-on-idle-emits-two-messages ()
  "`sprite-system-add-on-idle' emits one registration line then one sync line."
  (sprite-system-test/with-clean-state
    (let ((msgs (sprite-system-test/capture-messages
                  (sprite-system-add-on-idle #'ignore))))
      (should (= 2 (length msgs))))))

(ert-deftest sprite-system/add-on-idle-multiple-fns-all-on-hook ()
  "Multiple distinct fns can be added; all appear in the hook."
  (sprite-system-test/with-clean-state
    (cl-letf (((symbol-function 'message) #'ignore))
      (sprite-system-add-on-idle #'ignore)
      (sprite-system-add-on-idle #'identity)
      (should (memq #'ignore sprite-system-idle-hook))
      (should (memq #'identity sprite-system-idle-hook)))))

(ert-deftest sprite-system/add-on-idle-multiple-fns-timer-live ()
  "Timer stays running when multiple fns are registered."
  (sprite-system-test/with-clean-state
    (cl-letf (((symbol-function 'message) #'ignore))
      (sprite-system-add-on-idle #'ignore)
      (sprite-system-add-on-idle #'identity)
      (should (timerp sprite-system--idle-timer)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; sprite-system-remove-on-idle

(ert-deftest sprite-system/remove-on-idle-removes-fn-from-hook ()
  "`sprite-system-remove-on-idle' removes fn from `sprite-system-idle-hook'."
  (sprite-system-test/with-clean-state
    (cl-letf (((symbol-function 'message) #'ignore))
      (sprite-system-add-on-idle #'ignore)
      (sprite-system-remove-on-idle #'ignore)
      (should-not (memq #'ignore sprite-system-idle-hook)))))

(ert-deftest sprite-system/remove-on-idle-stops-timer-when-hook-empties ()
  "`sprite-system-remove-on-idle' stops the timer when the hook becomes empty."
  (sprite-system-test/with-clean-state
    (cl-letf (((symbol-function 'message) #'ignore))
      (sprite-system-add-on-idle #'ignore)
      (sprite-system-remove-on-idle #'ignore)
      (should (null sprite-system--idle-timer)))))

(ert-deftest sprite-system/remove-on-idle-keeps-timer-when-others-remain ()
  "Timer stays running after removing one fn when other fns remain."
  (sprite-system-test/with-clean-state
    (cl-letf (((symbol-function 'message) #'ignore))
      (sprite-system-add-on-idle #'ignore)
      (sprite-system-add-on-idle #'identity)
      (sprite-system-remove-on-idle #'ignore)
      (should (timerp sprite-system--idle-timer)))))

(ert-deftest sprite-system/remove-on-idle-logs-deregistration ()
  "`sprite-system-remove-on-idle' logs \"deregistered\" with the function name."
  (sprite-system-test/with-clean-state
    (cl-letf (((symbol-function 'message) #'ignore))
      (sprite-system-add-on-idle #'ignore))
    (let ((msgs (sprite-system-test/capture-messages
                  (sprite-system-remove-on-idle #'ignore))))
      (should (string-match-p "deregistered" (car msgs)))
      (should (string-match-p "ignore" (car msgs))))))

(ert-deftest sprite-system/remove-on-idle-emits-two-messages ()
  "`sprite-system-remove-on-idle' emits one deregistration then one sync line."
  (sprite-system-test/with-clean-state
    (cl-letf (((symbol-function 'message) #'ignore))
      (sprite-system-add-on-idle #'ignore))
    (let ((msgs (sprite-system-test/capture-messages
                  (sprite-system-remove-on-idle #'ignore))))
      (should (= 2 (length msgs))))))

(ert-deftest sprite-system/remove-nonexistent-fn-is-safe ()
  "Removing a fn that was never registered does not error."
  (sprite-system-test/with-clean-state
    (cl-letf (((symbol-function 'message) #'ignore))
      (sprite-system-remove-on-idle #'ignore))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; systemd-logind: availability predicate

(ert-deftest sprite-system/logind-unavailable-on-non-linux ()
  "`sprite-system--logind-available-p' returns nil on non-Linux systems."
  (let ((system-type 'darwin))
    (should-not (sprite-system--logind-available-p))))

(ert-deftest sprite-system/logind-unavailable-without-dbus ()
  "`sprite-system--logind-available-p' returns nil when dbus-register-signal is unbound."
  (let ((system-type 'gnu/linux))
    (cl-letf (((symbol-function 'fboundp)
               (lambda (sym)
                 (if (eq sym 'dbus-register-signal) nil (fboundp sym)))))
      (should-not (sprite-system--logind-available-p)))))

(ert-deftest sprite-system/logind-available-on-linux-with-dbus ()
  "`sprite-system--logind-available-p' returns non-nil on Linux with dbus."
  (let ((system-type 'gnu/linux))
    (cl-letf (((symbol-function 'fboundp)
               (lambda (sym)
                 (if (eq sym 'dbus-register-signal) t (fboundp sym)))))
      (should (sprite-system--logind-available-p)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; systemd-logind: start/stop watch

(ert-deftest sprite-system/start-logind-watch-calls-dbus-register ()
  "`sprite-system-start-logind-watch' calls `dbus-register-signal' on Linux."
  (sprite-system-test/with-clean-state
    (let ((dbus-called nil)
          (system-type 'gnu/linux))
      (cl-letf (((symbol-function 'fboundp)
                 (lambda (sym)
                   (if (eq sym 'dbus-register-signal) t (fboundp sym))))
                ((symbol-function 'dbus-register-signal)
                 (lambda (&rest _) (setq dbus-called t) 'fake-signal)))
        (sprite-system-start-logind-watch)
        (should dbus-called)
        (should (eq 'fake-signal sprite-system--logind-signal))))))

(ert-deftest sprite-system/start-logind-watch-noop-on-non-linux ()
  "`sprite-system-start-logind-watch' does not touch dbus on non-Linux."
  (sprite-system-test/with-clean-state
    (let ((dbus-called nil)
          (system-type 'darwin))
      (cl-letf (((symbol-function 'dbus-register-signal)
                 (lambda (&rest _) (setq dbus-called t))))
        (sprite-system-start-logind-watch)
        (should-not dbus-called)
        (should (null sprite-system--logind-signal))))))

(ert-deftest sprite-system/stop-logind-watch-unregisters-signal ()
  "`sprite-system-stop-logind-watch' calls `dbus-unregister-object' with the stored signal."
  (sprite-system-test/with-clean-state
    (let (unregistered)
      (setq sprite-system--logind-signal 'fake-signal)
      (cl-letf (((symbol-function 'dbus-unregister-object)
                 (lambda (obj) (push obj unregistered))))
        (sprite-system-stop-logind-watch)
        (should (member 'fake-signal unregistered))
        (should (null sprite-system--logind-signal))))))

(ert-deftest sprite-system/start-logind-watch-registers-all-signals ()
  "On Linux, `sprite-system-start-logind-watch' registers all sleep and lock/screensaver signals."
  (sprite-system-test/with-clean-state
    (let ((register-calls nil)
          (system-type 'gnu/linux)
          (orig-fboundp (symbol-function 'fboundp)))
      (cl-letf (((symbol-function 'fboundp)
                 (lambda (sym)
                   (if (eq sym 'dbus-register-signal) t (funcall orig-fboundp sym))))
                ((symbol-function 'dbus-register-signal)
                 (lambda (&rest args)
                   (push args register-calls)
                   (make-symbol (format "fake-signal-%d" (length register-calls))))))
        (sprite-system-start-logind-watch)
        (should (= 4 (length register-calls)))
        (should sprite-system--logind-signal)
        (should (= 3 (length sprite-system--dbus-signals)))
        ;; Verify signal names registered
        (let ((signals (seq-map (lambda (call) (nth 4 call)) (nreverse register-calls))))
          (should (equal '("PrepareForSleep" "Lock" "Unlock" "ActiveChanged") signals)))))))

(ert-deftest sprite-system/stop-logind-watch-unregisters-all-signals ()
  "`sprite-system-stop-logind-watch' unregisters all registered DBus signal objects."
  (sprite-system-test/with-clean-state
    (let (unregistered)
      (setq sprite-system--logind-signal 'fake-logind-sig)
      (setq sprite-system--dbus-signals '(fake-sig-1 fake-sig-2 fake-sig-3))
      (cl-letf (((symbol-function 'dbus-unregister-object)
                 (lambda (obj) (push obj unregistered))))
        (sprite-system-stop-logind-watch)
        (should (equal '(fake-logind-sig fake-sig-1 fake-sig-2 fake-sig-3) (nreverse unregistered)))
        (should (null sprite-system--logind-signal))
        (should (null sprite-system--dbus-signals))))))

(ert-deftest sprite-system/stop-logind-watch-noop-when-not-watching ()
  "`sprite-system-stop-logind-watch' does not error when signal var is nil."
  (sprite-system-test/with-clean-state
    (sprite-system-stop-logind-watch)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; sprite-system--on-prepare-for-sleep

(ert-deftest sprite-system/on-prepare-for-sleep-runs-hook-when-sleeping ()
  "`sprite-system--on-prepare-for-sleep' runs the before-sleep hook when arg is t."
  (let (run-hooks-arg)
    (cl-letf (((symbol-function 'run-hooks)
               (lambda (hook) (setq run-hooks-arg hook))))
      (sprite-system--on-prepare-for-sleep t)
      (should (eq 'sprite-system-before-sleep-hook run-hooks-arg)))))

(ert-deftest sprite-system/on-prepare-for-sleep-runs-after-sleep-hook-on-wake ()
  "`sprite-system--on-prepare-for-sleep' runs the after-sleep hook on wake (arg nil)."
  (let (run-hooks-arg)
    (cl-letf (((symbol-function 'run-hooks)
               (lambda (hook) (setq run-hooks-arg hook))))
      (sprite-system--on-prepare-for-sleep nil)
      (should (eq 'sprite-system-after-sleep-hook run-hooks-arg)))))

(ert-deftest sprite-system/on-prepare-for-sleep-does-not-run-before-sleep-on-wake ()
  "The before-sleep hook must not fire on wake — only the after-sleep hook should."
  (let (hooks-run)
    (cl-letf (((symbol-function 'run-hooks)
               (lambda (hook) (push hook hooks-run))))
      (sprite-system--on-prepare-for-sleep nil)
      (should-not (memq 'sprite-system-before-sleep-hook hooks-run)))))

(provide 'test-sprite-system)
;;; test-sprite-system.el ends here
