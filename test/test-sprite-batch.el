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

;; --- review follow-up tests ---
(defvar sprite-batch-test--timers nil)
(defvar sprite-batch-test-hook nil)

(defmacro sprite-batch-test--with-fake-timers (&rest body)
  "Run BODY with idle timers captured in `sprite-batch-test--timers'."
  (declare (indent 0))
  `(let ((noninteractive nil) (sprite-batch-test--timers nil) (sprite-batch--active-handles nil))
     (cl-letf (((symbol-function 'run-with-idle-timer)
                (lambda (secs _repeat fn &rest _)
                  (let ((rec (list secs fn))) (push rec sprite-batch-test--timers) rec)))
               ((symbol-function 'cancel-timer)
                (lambda (timer) (setq sprite-batch-test--timers (delete timer sprite-batch-test--timers)))))
       ,@body)))

(defun sprite-batch-test--drain ()
  "Fire captured timers until none remain ."
    (let ((n 0))
    (while (and sprite-batch-test--timers (< n 50))
      (funcall (cadr (pop sprite-batch-test--timers)))
      (cl-incf n))))

(ert-deftest sprite-batch/default-name ()
  "Unnamed batches get a batch-N name rather than the log prefix."
  (sprite-batch-test--with-fake-timers
    (sprite-run-batch :operations (list #'ignore))
    (should (string-match-p "\\`batch-[0-9]+\\'"
                            (sprite-batch-handle-name (car sprite-batch--active-handles))))))

(ert-deftest sprite-batch/error-isolated-and-on-done ()
  "A failing operation does not stop later ones; on-done runs once."
  (sprite-batch-test--with-fake-timers
    (let ((results nil) (done 0))
      (sprite-run-batch :operations (list (lambda () (error "boom"))
                                          (lambda () (push 'ok results)))
                        :on-done (lambda () (cl-incf done)))
      (sprite-batch-test--drain)
      (should (equal results '(ok)))
      (should (= done 1))
      (should (null sprite-batch--active-handles)))))

(ert-deftest sprite-batch/on-done-error-contained ()
  "An error in on-done is reported, and the handle is still finished."
  (sprite-batch-test--with-fake-timers
    (sprite-run-batch :operations (list #'ignore)
                      :on-done (lambda () (error "bad done")))
    (sprite-batch-test--drain)
    (should (null sprite-batch--active-handles))))

(ert-deftest sprite-batch/quit-in-operation-cancels ()
  "C-g (quit) inside an operation cancels the batch and unregisters it."
  (sprite-batch-test--with-fake-timers
    (let ((ran nil))
      (sprite-run-batch :operations (list (lambda () (signal 'quit nil))
                                          (lambda () (setq ran t))))
      (sprite-batch-test--drain)
      (should-not ran)
      (should (null sprite-batch--active-handles))
      (should (null sprite-batch-test--timers)))))

(ert-deftest sprite-batch/cancel-during-operation ()
  "An operation may cancel its own batch; no further step is scheduled."
  (sprite-batch-test--with-fake-timers
    (let ((ran nil))
      (sprite-run-batch :operations (list (lambda () (sprite-batch-cancel :all))
                                          (lambda () (setq ran t))))
      (sprite-batch-test--drain)
      (should-not ran)
      (should (null sprite-batch--active-handles)))))

(ert-deftest sprite-batch/cancel-returns-only-cancelled ()
  "Cancelling twice, by fn or unknown id, returns nil the second time."
  (sprite-batch-test--with-fake-timers
    (let* ((fn (sprite-run-batch :operations (list #'ignore)))
           (h (car sprite-batch--active-handles)))
      (should (equal (sprite-batch-cancel fn) (list h)))
      (should-not (sprite-batch-cancel fn))
      (should-not (sprite-batch-cancel h))
      (should-not (sprite-batch-cancel 99999))
      (should-error (sprite-batch-cancel "nope") :type 'user-error))))

(ert-deftest sprite-batch/empty-source-runs-on-done ()
  "An empty operation list runs on-done synchronously and registers nothing."
  (sprite-batch-test--with-fake-timers
    (let ((done nil))
      (sprite-run-batch :operations nil :on-done (lambda () (setq done t)))
      (should done)
      (should (null sprite-batch--active-handles)))))

(ert-deftest sprite-batch/hook-symbol-ignores-t ()
  "The global-value marker `t' in a hook is not run as an operation."
  (let ((noninteractive t) (results nil)
        (sprite-batch-test-hook nil))
    (setq sprite-batch-test-hook (list (lambda () (push 1 results)) t))
    (sprite-run-batch :operations 'sprite-batch-test-hook)
    (should (equal results '(1)))))

(ert-deftest sprite-batch/menu-all-stale-and-empty ()
  "Menu handles cancel-all, stale selections, and no active batches."
  (sprite-batch-test--with-fake-timers
    (should-not (sprite-batch-cancel-menu))
    (sprite-run-batch :operations (list #'ignore) :name "a")
    (sprite-run-batch :operations (list #'ignore) :name "b")
    (cl-letf (((symbol-function 'completing-read)
               (lambda (&rest _) "Cancel ALL active batches")))
      (sprite-batch-cancel-menu)
      (should (null sprite-batch--active-handles)))
    (sprite-run-batch :operations (list #'ignore) :name "c")
    (let ((cand (sprite-batch--candidate (car sprite-batch--active-handles))))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _) (sprite-batch-cancel :all) cand)))
        (sprite-batch-cancel-menu)))))

(ert-deftest sprite-batch/intercept-variable-syncs-mode ()
  "Setting the defcustom via `customize-set-variable' toggles the mode."
  (unwind-protect
      (progn
        (customize-set-variable 'sprite-batch-intercept-keyboard-quit t)
        (should sprite-batch-mode)
        (should (eq (lookup-key global-map [remap keyboard-quit])
                    #'sprite-batch-cancel-or-quit))
        (customize-set-variable 'sprite-batch-intercept-keyboard-quit nil)
        (should-not sprite-batch-mode)
        (should (null (lookup-key global-map [remap keyboard-quit]))))
    (sprite-batch-mode -1)))

(provide 'test-sprite-batch)
;;; test-sprite-batch.el ends here
