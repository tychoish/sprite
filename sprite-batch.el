;;; sprite-batch.el --- Yielding batch execution engine for sprite -*- lexical-binding: t; -*-

;; Author: Sam Kleinman
;; Keywords: tools, processes, convenience

;;; Commentary:
;; Sequential batch execution of operations yielding between tasks via idle
;; timers, with argument passing, error isolation, slow-op logging, and
;; execution in designated frame and buffer contexts.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'sprite)

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
                                 args arglist on-done frame buffer (log-prefix "[run]"))
  "Run OPERATIONS in order, yielding between each in interactive sessions.
OPERATIONS (or OPS) may be a list of functions, a single function,
or a symbol whose value is a list of functions (such as a hook).

Supported keyword arguments:
  :operations or :ops
    List of operations, single function, or hook symbol.
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

In noninteractive (batch) sessions, runs all operations synchronously.
Return a cancellation function."
  (let* ((source (or operations ops))
         (items (cond ((and (symbolp source) (boundp source)
                            (listp (symbol-value source)))
                       (symbol-value source))
                      (t (ensure-list source))))
         (wait (or run-after initial-delay delay))
         (fn-args (ensure-list (or args arglist))))
    (if (or noninteractive (null items))
        (progn
          (seq-do (lambda (op)
                    (sprite-batch--execute-operation op fn-args frame buffer log-prefix))
                  items)
          (when on-done (funcall on-done))
          #'ignore)
      (let* ((queue (copy-sequence items))
             (timer nil)
             (step nil))
        (setq step (lambda ()
                     (when queue
                       (sprite-batch--execute-operation (pop queue) fn-args frame buffer log-prefix)
                       (if queue
                           (setq timer (run-with-idle-timer delay nil step))
                         (when on-done (funcall on-done))))))
        (setq timer (run-with-idle-timer wait nil step))
        (lambda ()
          (setq queue nil)
          (when timer
            (cancel-timer timer)))))))

;;;###autoload
(defalias 'sprite-batch-run #'sprite-run-batch)

;;;###autoload
(defalias 'sprite-run #'sprite-run-batch)

;;;###autoload
(defun sprite-batch-startup (&optional operations &rest args)
  "Run startup OPERATIONS yielding between each in interactive sessions.
OPERATIONS defaults to `sprite-startup-operations'.
Supported ARGS keyword arguments include :delay, :run-after, :on-done, :frame,
and :buffer.
Specialized case of `sprite-run-batch' with default args `(1)' and log
prefix \"[startup]\"."
  (let ((kwargs (if (keywordp operations)
                    (cons operations args)
                  (append (list :operations (or operations sprite-startup-operations))
                          args))))
    (apply #'sprite-run-batch (append kwargs (list :operations sprite-startup-operations
                                                   :args '(1)
                                                   :log-prefix "[startup]")))))

;;;###autoload
(defalias 'sprite-run-startup-operations #'sprite-batch-startup)

(provide 'sprite-batch)
;;; sprite-batch.el ends here
