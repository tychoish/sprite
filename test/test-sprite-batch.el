;;; test-sprite-batch.el --- ERT tests for sprite-batch.el -*- lexical-binding: t; no-byte-compile: t; -*-

;; Run inside a live Emacs session:
;;   (ert "^sprite-batch/")

;;; Commentary:
;; Tests for sprite-batch.el execution engine, context macros, buffer/frame isolation,
;; and startup-operations forwarding.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'sprite-batch)

(ert-deftest sprite-batch/run-args-batch-sync ()
  "sprite-run-batch executes operations with :args in batch mode."
  (let ((results nil)
        (done nil)
        (noninteractive t))
    (sprite-run-batch
     :operations (list (lambda () (push 'zero results))
                       (lambda (x y) (push (+ x y) results)))
     :args '(10 20)
     :log-prefix "[test-batch]"
     :on-done (lambda () (setq done t)))
    (should (equal (reverse results) '(zero 30)))
    (should (eq done t))))

(ert-deftest sprite-batch/run-ops-alias ()
  "sprite-run-batch accepts :ops as an alias for :operations."
  (let ((results nil)
        (noninteractive t))
    (sprite-run-batch :ops (list (lambda () (push 'ok results))))
    (should (equal results '(ok)))))

(defvar sprite-test--fake-batch-hook nil)

(ert-deftest sprite-batch/run-hook-symbol ()
  "sprite-run-batch can take a symbol whose value is a list of functions."
  (let* ((order nil)
         (noninteractive t)
         (sprite-test--fake-batch-hook (list (lambda (arg) (push (cons 1 arg) order))
                                             (lambda (arg) (push (cons 2 arg) order)))))
    (sprite-run-batch :operations 'sprite-test--fake-batch-hook :args 'active)
    (should (equal (reverse order) '((1 . active) (2 . active))))))

(ert-deftest sprite-batch/run-initial-delay-and-cancellation ()
  "sprite-run-batch schedules with :run-after and cancellation stops execution."
  (let ((noninteractive nil)
        (executed nil)
        (timers nil))
    (cl-letf (((symbol-function 'run-with-idle-timer)
               (lambda (secs repeat fn &rest args)
                 (let ((rec (list secs fn)))
                   (push rec timers)
                   rec)))
              ((symbol-function 'cancel-timer)
               (lambda (timer)
                 (setq timers (delete timer timers)))))
      (let ((cancel-fn (sprite-run-batch :operations (list (lambda () (setq executed t)))
                                         :run-after 2.5
                                         :delay 0.5)))
        (should (= (caar timers) 2.5))
        (funcall cancel-fn)
        (should (null timers))))))

(ert-deftest sprite-batch/run-temp-buffer-context ()
  "sprite-run-batch with :buffer 'temp executes each step in a temp buffer."
  (let ((buffer-names nil)
        (noninteractive t))
    (sprite-run-batch
     :operations (list (lambda () (push (buffer-name) buffer-names))
                       (lambda () (push (buffer-name) buffer-names)))
     :buffer 'temp)
    (should (equal (length buffer-names) 2))
    (should (seq-every-p (lambda (name) (string-prefix-p " *temp*" name))
                         buffer-names))))

(ert-deftest sprite-batch/run-named-buffer-context ()
  "sprite-run-batch with string :buffer executes in that named buffer."
  (let ((buf-name " *sprite-batch-test*")
        (executed-in nil)
        (noninteractive t))
    (unwind-protect
        (progn
          (sprite-run-batch
           :operations (list (lambda () (push (buffer-name) executed-in)))
           :buffer buf-name)
          (should (equal executed-in (list buf-name))))
      (when (get-buffer buf-name)
        (kill-buffer buf-name)))))

(ert-deftest sprite-batch/run-buffer-object-context ()
  "sprite-run-batch with live buffer object executes in that buffer."
  (let* ((buf (generate-new-buffer " *sprite-batch-obj*"))
         (executed-in nil)
         (noninteractive t))
    (unwind-protect
        (progn
          (sprite-run-batch
           :operations (list (lambda () (push (current-buffer) executed-in)))
           :buffer buf)
          (should (equal executed-in (list buf))))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest sprite-batch/run-dead-buffer-skips-safely ()
  "sprite-run-batch with a dead buffer skips execution safely without error."
  (let* ((buf (generate-new-buffer " *sprite-batch-dead*"))
         (executed nil)
         (noninteractive t))
    (kill-buffer buf)
    (sprite-run-batch
     :operations (list (lambda () (setq executed t)))
     :buffer buf)
    (should (null executed))))

(ert-deftest sprite-batch/aliases ()
  "sprite-batch-run and sprite-run are aliases for sprite-run-batch."
  (let ((r1 nil)
        (r2 nil)
        (noninteractive t))
    (sprite-batch-run :operations (list (lambda () (push 1 r1))))
    (sprite-run :operations (list (lambda () (push 2 r2))))
    (should (equal r1 '(1)))
    (should (equal r2 '(2)))))

(ert-deftest sprite-batch/startup-forwarding ()
  "sprite-batch-startup forwards kwargs to sprite-run-batch."
  (let ((sprite-startup-operations (list (lambda () t)))
        (noninteractive nil)
        (timers nil))
    (cl-letf (((symbol-function 'run-with-idle-timer)
               (lambda (secs repeat fn &rest args)
                 (let ((rec (list secs fn)))
                   (push rec timers)
                   rec)))
              ((symbol-function 'cancel-timer)
               (lambda (timer)
                 (setq timers (delete timer timers)))))
      (let ((cancel-fn (sprite-batch-startup :run-after 4.0 :delay 0.3)))
        (should (= (caar timers) 4.0))
        (funcall cancel-fn)
        (should (null timers))))))

(provide 'test-sprite-batch)
;;; test-sprite-batch.el ends here
