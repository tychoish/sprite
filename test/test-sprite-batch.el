;;; test-sprite-batch.el --- ERT tests for sprite-batch.el -*- lexical-binding: t; no-byte-compile: t; -*-

;; Run inside a live Emacs session:
;;   (ert "^sprite-batch/")

;;; Commentary:
;; Tests for sprite-batch.el execution engine, context macros, buffer/frame isolation,
;; and startup-operations forwarding.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'generator)
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

(ert-deftest sprite-batch/generator-iterator ()
  "sprite-run-batch supports generator.el iterators via iter-make."
  (let ((results nil)
        (noninteractive t))
    (let ((gen (iter-make (iter-yield (lambda () (push 'first results)))
                          (iter-yield (lambda () (push 'second results))))))
      (sprite-run-batch :operations gen)
      (should (equal (reverse results) '(first second))))))

(ert-deftest sprite-batch/vector-source ()
  "sprite-run-batch supports vector collections."
  (let ((results nil)
        (noninteractive t))
    (sprite-run-batch :operations (vector (lambda () (push 1 results))
                                          (lambda () (push 2 results))))
    (should (equal (reverse results) '(1 2)))))

(ert-deftest sprite-batch/single-function ()
  "sprite-run-batch supports a single function as :operations."
  (let ((results nil)
        (noninteractive t))
    (sprite-run-batch :operations (lambda () (push 'single results)))
    (should (equal results '(single)))))

(ert-deftest sprite-batch/active-handles-tracking-and-stepping ()
  "sprite-batch tracks active handles and advances current count during stepping."
  (let ((noninteractive nil)
        (timers nil)
        (results nil))
    (cl-letf (((symbol-function 'run-with-idle-timer)
               (lambda (secs repeat fn &rest args)
                 (let ((rec (list secs fn)))
                   (push rec timers)
                   rec)))
              ((symbol-function 'cancel-timer)
               (lambda (timer)
                 (setq timers (delete timer timers)))))
      (let* ((cancel-fn (sprite-run-batch
                         :operations (list (lambda () (push 'a results))
                                           (lambda () (push 'b results)))
                         :name "test-step"
                         :delay 0.2))
             (handles (sprite-batch-active-handles)))
        (should (= (length handles) 1))
        (let ((handle (car handles)))
          (should (string= (sprite-batch-handle-name handle) "test-step"))
          (should (eq (sprite-batch-handle-state handle) 'running))
          (should (= (sprite-batch-handle-total handle) 2))
          (should (= (sprite-batch-handle-current handle) 0))
          ;; Step first operation
          (funcall (cadr (pop timers)))
          (should (equal results '(a)))
          (should (= (sprite-batch-handle-current handle) 1))
          ;; Step second operation
          (funcall (cadr (pop timers)))
          (should (equal (reverse results) '(a b)))
          (should (= (sprite-batch-handle-current handle) 2))
          ;; Step terminal
          (funcall (cadr (pop timers)))
          (should (eq (sprite-batch-handle-state handle) 'done))
          (should (null (sprite-batch-active-handles))))))))

(ert-deftest sprite-batch/cancel-by-handle ()
  "sprite-batch-cancel cancels a specific handle."
  (let ((noninteractive nil)
        (timers nil))
    (cl-letf (((symbol-function 'run-with-idle-timer)
               (lambda (secs repeat fn &rest args)
                 (let ((rec (list secs fn)))
                   (push rec timers)
                   rec)))
              ((symbol-function 'cancel-timer)
               (lambda (timer)
                 (setq timers (delete timer timers)))))
      (sprite-run-batch :operations (list (lambda () t)) :name "batch-1")
      (let* ((h1 (car (sprite-batch-active-handles)))
             (cancelled (sprite-batch-cancel h1)))
        (should (equal cancelled (list h1)))
        (should (eq (sprite-batch-handle-state h1) 'cancelled))
        (should (null (sprite-batch-active-handles)))))))

(ert-deftest sprite-batch/cancel-by-id ()
  "sprite-batch-cancel cancels by integer id."
  (let ((noninteractive nil)
        (timers nil))
    (cl-letf (((symbol-function 'run-with-idle-timer)
               (lambda (secs repeat fn &rest args)
                 (let ((rec (list secs fn)))
                   (push rec timers)
                   rec)))
              ((symbol-function 'cancel-timer)
               (lambda (timer)
                 (setq timers (delete timer timers)))))
      (sprite-run-batch :operations (list (lambda () t)) :name "batch-id-test")
      (let* ((h (car (sprite-batch-active-handles)))
             (id (sprite-batch-handle-id h)))
        (should (equal (sprite-batch-cancel id) (list h)))
        (should (null (sprite-batch-active-handles)))))))

(ert-deftest sprite-batch/cancel-all ()
  "sprite-batch-cancel with :all cancels all active batches."
  (let ((noninteractive nil)
        (timers nil))
    (cl-letf (((symbol-function 'run-with-idle-timer)
               (lambda (secs repeat fn &rest args)
                 (let ((rec (list secs fn)))
                   (push rec timers)
                   rec)))
              ((symbol-function 'cancel-timer)
               (lambda (timer)
                 (setq timers (delete timer timers)))))
      (sprite-run-batch :operations (list (lambda () t)) :name "b1")
      (sprite-run-batch :operations (list (lambda () t)) :name "b2")
      (should (= (length (sprite-batch-active-handles)) 2))
      (let ((cancelled (sprite-batch-cancel :all)))
        (should (= (length cancelled) 2))
        (should (null (sprite-batch-active-handles)))))))

(ert-deftest sprite-batch/cancel-or-quit-passthrough ()
  "sprite-batch-cancel-or-quit calls keyboard-quit when no batches are running or in region/minibuffer."
  (let ((quit-called 0))
    (cl-letf (((symbol-function 'keyboard-quit)
               (lambda () (cl-incf quit-called))))
      ;; 1. No active batches -> immediate keyboard-quit
      (let ((sprite-batch--active-handles nil))
        (sprite-batch-cancel-or-quit)
        (should (= quit-called 1)))
      ;; 2. Active batch, but use-region-p is true -> keyboard-quit
      (let ((sprite-batch--active-handles (list (sprite-batch-handle--make :id 99 :state 'running))))
        (cl-letf (((symbol-function 'use-region-p) (lambda () t)))
          (sprite-batch-cancel-or-quit)
          (should (= quit-called 2))))
      ;; 3. Active batch, but inside minibuffer -> keyboard-quit
      (let ((sprite-batch--active-handles (list (sprite-batch-handle--make :id 99 :state 'running))))
        (cl-letf (((symbol-function 'minibufferp) (lambda () t)))
          (sprite-batch-cancel-or-quit)
          (should (= quit-called 3)))))))

(ert-deftest sprite-batch/cancel-menu-selection ()
  "sprite-batch-cancel-menu displays candidates and dispatches choice."
  (let* ((cancelled nil)
         (h1 (sprite-batch-handle--make
              :id 1 :name "job-one" :state 'running :current 1 :total 3
              :cancel-fn (lambda () (setq cancelled t))))
         (sprite-batch--active-handles (list h1)))
    ;; 1. User picks Quit -> keyboard-quit called
    (let ((quit-called nil))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (prompt table &rest _) "Quit / Cancel normal operation"))
                ((symbol-function 'annotated-completing-read)
                 (lambda (table &rest _) "Quit / Cancel normal operation"))
                ((symbol-function 'keyboard-quit)
                 (lambda () (setq quit-called t))))
        (sprite-batch-cancel-menu)
        (should (eq quit-called t))))
    ;; 2. User picks specific batch -> cancelled
    (cl-letf (((symbol-function 'completing-read)
               (lambda (prompt table &rest _) "#1: job-one"))
              ((symbol-function 'annotated-completing-read)
               (lambda (table &rest _) "#1: job-one")))
      (sprite-batch-cancel-menu)
      (should (eq cancelled t)))))

(ert-deftest sprite-batch/mode-toggle-keymap ()
  "sprite-batch-mode toggles remapping of keyboard-quit."
  (unwind-protect
      (progn
        (sprite-batch-mode 1)
        (should (eq sprite-batch-intercept-keyboard-quit t))
        (should (eq (lookup-key global-map [remap keyboard-quit])
                    #'sprite-batch-cancel-or-quit))
        (sprite-batch-mode -1)
        (should (eq sprite-batch-intercept-keyboard-quit nil))
        (should (null (lookup-key global-map [remap keyboard-quit]))))
    (sprite-batch-mode -1)))

(provide 'test-sprite-batch)
;;; test-sprite-batch.el ends here
