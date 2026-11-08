;;; sprite-batch.el --- Yielding batch execution engine for sprite -*- lexical-binding: t; -*-

;; Author: Sam Kleinman
;; Keywords: tools, processes, convenience

;;; Commentary:
;; Sequential batch execution of operations yielding between tasks via idle
;; timers, with argument passing, error isolation, slow-op logging, and
;; execution in designated frame and buffer contexts.
;; Provides ACR-backed cancellation and keyboard-quit interception.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'sprite)

(declare-function annotated-completing-read "annotated-completing-read" (table &rest args))

(cl-defstruct (sprite-batch-handle (:constructor sprite-batch-handle--make) (:copier nil))
  "Handle for an active batch execution."
  id                 ; unique integer ID
  name               ; human-readable batch name or prefix
  state              ; 'running, 'cancelled, 'done
  (current 0)        ; completed items count
  total              ; total items count (integer or nil)
  timer              ; idle timer handle
  cancel-fn          ; cancellation function
  created-at)        ; start timestamp

(defvar sprite-batch--active-handles nil
  "List of currently active `sprite-batch-handle' instances.")

(defvar sprite-batch--id-counter 0
  "Monotonically increasing ID counter for batch operations.")

(defun sprite-batch-active-handles ()
  "Return a copy of the currently active `sprite-batch-handle' instances."
  (copy-sequence sprite-batch--active-handles))

(defmacro sprite-batch--with-context (frame buffer &rest body)
  "Execute BODY with optional FRAME and BUFFER context.
If BUFFER is `temp', BODY executes inside `with-temp-buffer'.
If BUFFER is a buffer or string name, BODY executes in that buffer.
If FRAME is non-nil and live, BODY executes with FRAME selected."
  (declare (indent 2))
  (let ((buf-sym (gensym "buf"))
        (frm-sym (gensym "frm")))
    `(let ((,frm-sym ,frame)
           (,buf-sym ,buffer))
       (when (or (null ,frm-sym) (frame-live-p ,frm-sym))
         (with-selected-frame (or ,frm-sym (selected-frame))
           (cond ((eq ,buf-sym 'temp)
                  (with-temp-buffer ,@body))
                 ((bufferp ,buf-sym)
                  (when (buffer-live-p ,buf-sym)
                    (with-current-buffer ,buf-sym ,@body)))
                 ((stringp ,buf-sym)
                  (with-current-buffer (get-buffer-create ,buf-sym) ,@body))
                 (t ,@body)))))))

(defun sprite-batch--execute-operation (fn &optional args frame buffer log-prefix)
  "Run operation FN with ARGS in FRAME and BUFFER context, reporting errors.
When `sprite-slow-op-reporting' or `init-file-debug' is non-nil,
log operation duration with LOG-PREFIX if it exceeds `sprite-slow-op-threshold'."
  (condition-case err
      (sprite-batch--with-context frame buffer
        (when (and (symbolp fn) (fboundp fn) (autoloadp (symbol-function fn)))
          (autoload-do-load (symbol-function fn) fn))
        (with-sprite-slow-op-timer (format "%s %s" (or log-prefix "[run]") fn)
          (if (equal (cdr (func-arity fn)) 0)
              (funcall fn)
            (apply fn (ensure-list args)))))
    (error (message "[sprite] %s failed: %s" fn (error-message-string err)))))

;;;###autoload
(cl-defun sprite-run-batch (&key operations ops (delay 0.1) run-after initial-delay
                                 args arglist on-done frame buffer (log-prefix "[run]")
                                 name)
  "Run OPERATIONS in order, yielding between each in interactive sessions.
OPERATIONS (or OPS) may be a list of functions, a vector, a generator
iterator, a gen stream, a single function, or a symbol whose value is
a list of functions (such as a hook).

Supported keyword arguments:
  :operations or :ops
    List of operations, vector, generator iterator, single function,
    or hook symbol.
  :run-after or :initial-delay SECONDS
    Initial delay before the first operation (defaults to :delay).
  :delay SECONDS
    Amount of idle time between operations (defaults to 0.1).
  :args or :arglist LIST or ATOM
    Arguments passed to any non-nilary operation.
  :on-done FUNCTION
    Callback invoked when all operations finish.
  :frame FRAME
    Optional frame context for `with-selected-frame'.
  :buffer BUFFER
    Optional buffer context: `temp' executes in `with-temp-buffer',
    a buffer object or string name executes in `with-current-buffer'.
  :log-prefix STRING
    Timer log prefix (defaults to \"[run]\").
  :name STRING
    Human-readable batch identifier for status display and cancel menus.

In noninteractive (batch) sessions, runs all operations synchronously.
Return a cancellation function."
  (let* ((source (or operations ops))
         (items (cond ((and (symbolp source) (boundp source)
                            (listp (symbol-value source)))
                       (symbol-value source))
                      ((and (symbolp source) (fboundp source))
                       (list source))
                      ((and (functionp source)
                            (not (equal (func-arity source) '(2 . 2)))
                            (not (and (fboundp 'gen-p) (funcall 'gen-p source))))
                       (list source))
                      (t source)))
         (iter (sprite--make-iterator items))
         (total (car iter))
         (next-fn (cdr iter))
         (wait (or run-after initial-delay delay 0.1))
         (delay-sec (or delay 0.1))
         (fn-args (ensure-list (or args arglist))))
    (if (or noninteractive (eq total 0))
        (progn
          (let ((next (funcall next-fn)))
            (while next
              (let ((op (cdr next)))
                (sprite-batch--execute-operation op fn-args frame buffer log-prefix))
              (setq next (funcall next-fn))))
          (when on-done (funcall on-done))
          #'ignore)
      (let* ((batch-id (cl-incf sprite-batch--id-counter))
             (batch-name (or name log-prefix (format "batch-%d" batch-id)))
             (handle (sprite-batch-handle--make
                      :id batch-id
                      :name batch-name
                      :state 'running
                      :current 0
                      :total total
                      :timer nil
                      :cancel-fn nil
                      :created-at (current-time))))
        (letrec ((timer nil)
                 (cancel-fn
                  (lambda ()
                    (when (eq (sprite-batch-handle-state handle) 'running)
                      (setf (sprite-batch-handle-state handle) 'cancelled)
                      (when timer
                        (cancel-timer timer)
                        (setq timer nil))
                      (setf (sprite-batch-handle-timer handle) nil)
                      (setq sprite-batch--active-handles
                            (delq handle sprite-batch--active-handles))
                      t)))
                 (step
                  (lambda ()
                    (if (not (eq (sprite-batch-handle-state handle) 'running))
                        (progn
                          (when timer (cancel-timer timer))
                          (setq sprite-batch--active-handles
                                (delq handle sprite-batch--active-handles)))
                      (let ((next (funcall next-fn)))
                        (if next
                            (let ((op (cdr next)))
                              (cl-incf (sprite-batch-handle-current handle))
                              (sprite-batch--execute-operation op fn-args frame buffer log-prefix)
                              (if (eq (sprite-batch-handle-state handle) 'running)
                                  (let ((next-timer (run-with-idle-timer delay-sec nil step)))
                                    (setq timer next-timer)
                                    (setf (sprite-batch-handle-timer handle) next-timer))
                                (when timer (cancel-timer timer))
                                (setq sprite-batch--active-handles
                                      (delq handle sprite-batch--active-handles))))
                          (setf (sprite-batch-handle-state handle) 'done)
                          (setf (sprite-batch-handle-timer handle) nil)
                          (setq sprite-batch--active-handles
                                (delq handle sprite-batch--active-handles))
                          (when on-done (funcall on-done))))))))
          (setf (sprite-batch-handle-cancel-fn handle) cancel-fn)
          (push handle sprite-batch--active-handles)
          (let ((first-timer (run-with-idle-timer wait nil step)))
            (setq timer first-timer)
            (setf (sprite-batch-handle-timer handle) first-timer))
          cancel-fn)))))

;;;###autoload
(defalias 'sprite-batch-run #'sprite-run-batch)

;;;###autoload
(defalias 'sprite-run #'sprite-run-batch)

;;;###autoload
(defun sprite-batch-startup (&optional operations &rest args)
  "Run startup OPERATIONS yielding between each in interactive sessions.
OPERATIONS defaults to `sprite-startup-operations'.
Supported ARGS keyword arguments include :delay, :run-after, :on-done, :frame,
:buffer, and :name.
Specialized case of `sprite-run-batch' with default args `(1)' and log
prefix \"[startup]\"."
  (let* ((has-ops (not (or (null operations) (keywordp operations))))
         (ops (if has-ops operations sprite-startup-operations))
         (rest-args (if (keywordp operations)
                        (cons operations args)
                      args))
         (defaults (list :operations ops
                         :args '(1)
                         :log-prefix "[startup]"
                         :name "startup")))
    (apply #'sprite-run-batch (append rest-args defaults))))

;;;###autoload
(defalias 'sprite-run-startup-operations #'sprite-batch-startup)

;;;###autoload
(defun sprite-batch-cancel (&optional target)
  "Cancel in-flight batch execution identified by TARGET.
TARGET may be:
- `:all' to cancel all active batches
- A `sprite-batch-handle' instance
- An integer batch ID
- A cancellation function returned by `sprite-run-batch'
- nil (or interactively with no prefix): prompt via `sprite-batch-cancel-menu'.
Return the list of cancelled handles."
  (interactive)
  (cond
   ((eq target :all)
    (let ((handles (copy-sequence sprite-batch--active-handles)))
      (dolist (h handles)
        (when (sprite-batch-handle-cancel-fn h)
          (funcall (sprite-batch-handle-cancel-fn h))))
      (when (called-interactively-p 'interactive)
        (message "[sprite-batch] Cancelled %d batches" (length handles)))
      handles))
   ((null target)
    (if (called-interactively-p 'interactive)
        (sprite-batch-cancel-menu)
      (let ((handles (copy-sequence sprite-batch--active-handles)))
        (dolist (h handles)
          (when (sprite-batch-handle-cancel-fn h)
            (funcall (sprite-batch-handle-cancel-fn h))))
        handles)))
   ((sprite-batch-handle-p target)
    (when (sprite-batch-handle-cancel-fn target)
      (funcall (sprite-batch-handle-cancel-fn target)))
    (when (called-interactively-p 'interactive)
      (message "[sprite-batch] Cancelled batch #%d (%s)"
               (sprite-batch-handle-id target)
               (sprite-batch-handle-name target)))
    (list target))
   ((integerp target)
    (let ((handle (cl-find target sprite-batch--active-handles
                           :key #'sprite-batch-handle-id)))
      (when handle
        (when (sprite-batch-handle-cancel-fn handle)
          (funcall (sprite-batch-handle-cancel-fn handle)))
        (when (called-interactively-p 'interactive)
          (message "[sprite-batch] Cancelled batch #%d (%s)"
                   (sprite-batch-handle-id handle)
                   (sprite-batch-handle-name handle)))
        (list handle))))
   ((functionp target)
    (let ((handle (cl-find target sprite-batch--active-handles
                           :key #'sprite-batch-handle-cancel-fn)))
      (funcall target)
      (and handle (list handle))))
   (t
    (user-error "Unknown batch target: %S" target))))

;;;###autoload
(defun sprite-batch-cancel-menu ()
  "Interactively select an active batch to cancel, cancel all, or quit."
  (interactive)
  (let ((active (sprite-batch-active-handles)))
    (if (null active)
        (progn
          (message "[sprite-batch] No active batches running")
          nil)
      (let* ((quit-candidate "Quit / Cancel normal operation")
             (quit-annotation "Pass through to keyboard-quit")
             (all-candidate "Cancel ALL active batches")
             (all-annotation (format "%d batches active" (length active)))
             (candidates nil))
        (push (cons quit-candidate quit-annotation) candidates)
        (dolist (h active)
          (let* ((id (sprite-batch-handle-id h))
                 (name (sprite-batch-handle-name h))
                 (curr (sprite-batch-handle-current h))
                 (tot (sprite-batch-handle-total h))
                 (cand (format "#%d: %s" id name))
                 (ann (if tot
                          (format "%d/%d completed" curr tot)
                        (format "%d completed" curr))))
            (push (cons cand ann) candidates)))
        (when (> (length active) 1)
          (push (cons all-candidate all-annotation) candidates))
        (setq candidates (nreverse candidates))
        (let* ((choice (if (fboundp 'annotated-completing-read)
                           (annotated-completing-read
                            candidates
                            :prompt "Select batch to cancel: "
                            :require-match t
                            :default quit-candidate)
                         (completing-read "Select batch to cancel: "
                                          candidates
                                          nil t nil nil quit-candidate))))
          (cond
           ((or (null choice) (string= choice "") (string= choice quit-candidate))
            (keyboard-quit))
           ((string= choice all-candidate)
            (sprite-batch-cancel :all))
           (t
            (let* ((id (and (string-match "\\`#\\([0-9]+\\):" choice)
                            (string-to-number (match-string 1 choice))))
                   (handle (and id (cl-find id active :key #'sprite-batch-handle-id))))
              (if handle
                  (sprite-batch-cancel handle)
                (message "[sprite-batch] Batch %s no longer active" choice))))))))))

;;;###autoload
(defun sprite-batch-cancel-or-quit ()
  "Cancel an in-flight batch, or pass through to `keyboard-quit'.
When background batches are active, present an ACR menu allowing cancellation
of specific batches or continuing to normal keyboard quit.
When no batches are running, or when invoked within the minibuffer or an active
region, immediately call `keyboard-quit'."
  (interactive)
  (if (or (minibufferp)
          (use-region-p)
          (null sprite-batch--active-handles))
      (keyboard-quit)
    (sprite-batch-cancel-menu)))

;;;###autoload
(defcustom sprite-batch-intercept-keyboard-quit nil
  "When non-nil, remap `keyboard-quit' to `sprite-batch-cancel-or-quit'.
When active batches are running, `C-g' will present a menu to cancel running
batches or perform normal keyboard quit.  When no batches are running,
it behaves identically to `keyboard-quit'."
  :type 'boolean
  :group 'sprite-batch
  :set (lambda (sym val)
         (set-default sym val)
         (if val
             (define-key global-map [remap keyboard-quit] #'sprite-batch-cancel-or-quit)
           (when (eq (lookup-key global-map [remap keyboard-quit]) #'sprite-batch-cancel-or-quit)
             (define-key global-map [remap keyboard-quit] nil)))))

;;;###autoload
(define-minor-mode sprite-batch-mode
  "Global minor mode to intercept `keyboard-quit' for running sprite batches."
  :global t
  :group 'sprite-batch
  (if sprite-batch-mode
      (progn
        (setq sprite-batch-intercept-keyboard-quit t)
        (define-key global-map [remap keyboard-quit] #'sprite-batch-cancel-or-quit))
    (setq sprite-batch-intercept-keyboard-quit nil)
    (when (eq (lookup-key global-map [remap keyboard-quit]) #'sprite-batch-cancel-or-quit)
      (define-key global-map [remap keyboard-quit] nil))))

(provide 'sprite-batch)
;;; sprite-batch.el ends here
