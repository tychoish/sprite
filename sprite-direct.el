;;; sprite-direct.el --- Direct socket communication with Emacs server processes -*- lexical-binding: t; -*-

;; Author: Sam Kleinman
;; Version: 0.2.0
;; Package-Requires: ((emacs "29.1") (seq "2.24") (map "3.0"))
;; Keywords: tools, daemon, processes

;; This package is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;;; Commentary:
;;
;; Implements the Emacs server wire protocol over Unix domain sockets and TCP
;; connections, allowing Lisp forms to be evaluated in a running Emacs daemon
;; without invoking the emacsclient binary.
;;
;; The protocol is text-based:
;;   Client → Server:  -auth KEY -eval ENCODED_FORM \n
;;   Server → Client:  -print ENCODED_RESULT\n  or  -error ENCODED_MSG\n
;;
;; Special characters in encoded values: & → &&, - → &-, space → &_,
;; newline → &n.  This mirrors `server-quote-arg'/`server-unquote-arg'.
;;
;; The central abstraction is `sprite-direct-conn', a lightweight context
;; object created by `sprite-direct-open' or `with-sprite-direct'.  Each
;; operation opens a transient socket, exchanges one request/response pair,
;; and closes it — the conn holds no persistent socket.
;;
;; Blocking receive uses generator.el: `sprite-direct--recv-gen' yields
;; `:pending' while the response buffer is empty, allowing
;; `accept-process-output' to run between polls.  Timeout behaviour is
;; governed by `sprite-direct-blocking-timeout' and
;; `sprite-direct-yield-interval', both `defvar's for dynamic override.
;;
;; Non-blocking evaluation returns a `sprite-direct-promise' that resolves
;; via a process sentinel when the server closes the connection.
;;
;; Entry points:
;;   `with-sprite-direct'               — open a connection context
;;   `sprite-direct-open'               — open a conn imperatively
;;   `sprite-direct-eval-blocking'      — synchronous eval (generator-backed)
;;   `sprite-direct-call-and-read'      — drop-in for sprite--call-and-read
;;   `sprite-direct-eval-non-blocking'  — async eval returning a promise
;;   `sprite-direct-promise-pending-p'  — predicate: not yet resolved
;;   `sprite-direct-promise-resolved-p' — predicate: successfully resolved
;;   `sprite-direct-promise-wait'       — block until promise resolves
;;   `sprite-direct-list-buffers'       — list buffer names in the sprite
;;   `sprite-direct-insert-into-buffer' — insert text at a position
;;   `with-current-sprite-direct-buffer'— eval body in a remote buffer
;;   `sprite-direct-read-buffer'        — read buffer contents
;;   `sprite-direct-value-of-symbol'    — read a symbol's value
;;   `sprite-direct-read-tcp-server-file' — read a TCP server file

;;; Code:

(eval-when-compile
  (require 'cl-lib))
(require 'generator)
(require 'map)
(require 'seq)
(require 'subr-x)

;; Declare server.el variables; server.el is loaded by any running daemon
;; but may be absent in batch/test contexts.
(defvar server-socket-dir)
(defvar server-auth-dir)

;;;; Timeout and interval configuration

(defvar sprite-direct-blocking-timeout nil
  "Seconds to wait in blocking receives, or nil to block indefinitely.
Dynamically override per call-site with `let' to impose a local limit.")

(defvar sprite-direct-yield-interval 0.05
  "Seconds passed to `accept-process-output' between generator yields.
Smaller values increase responsiveness at the cost of CPU spin.")

(defvar sprite-direct-async-check-interval 0.1
  "Seconds between event polls in `sprite-direct-promise-wait'.")

;;;; Wire-protocol encoding

(defun sprite-direct--encode (str)
  "Encode STR for the Emacs server wire protocol.
Mirrors `server-quote-arg': & → &&, - → &-, space → &_, newline → &n."
  (replace-regexp-in-string
   "[-& \n]"
   (lambda (s)
     (pcase s
       ("&" "&&")
       ("-" "&-")
       ("\n" "&n")
       (_ "&_")))
   str t t))

(defun sprite-direct--decode (str)
  "Decode STR from the Emacs server wire protocol.
Mirrors `server-unquote-arg': && → &, &- → -, &_ → space, &n → newline."
  (replace-regexp-in-string
   "&."
   (lambda (s)
     (pcase (aref s 1)
       (?& "&")
       (?- "-")
       (?n "\n")
       (_ " ")))
   str t t))

;;;; Connection parsing

(defun sprite-direct--parse-tcp (target)
  "Parse TARGET as a HOST:PORT:KEY TCP server string.
Returns a connection plist with :type, :host, :port, :key, or nil when
TARGET does not match the HOST:PORT:KEY pattern."
  (when (string-match "^\\(.*\\):\\([0-9]+\\):\\(.*\\)$" target)
    (list :type 'tcp
          :host (match-string 1 target)
          :port (string-to-number (match-string 2 target))
          :key (match-string 3 target))))

(defun sprite-direct--read-auth-key (name)
  "Return the auth key for server NAME from `server-auth-dir', or nil.
The auth file is written by server.el when the Emacs server starts."
  (when (and (boundp 'server-auth-dir) server-auth-dir)
    (let ((path (expand-file-name name server-auth-dir)))
      (when (file-readable-p path)
        (with-temp-buffer
          (insert-file-contents path)
          (string-trim (buffer-string)))))))

(defun sprite-direct--socket-path (name)
  "Return the Unix socket path for server NAME, or nil when unavailable."
  (when (and (boundp 'server-socket-dir) server-socket-dir)
    (expand-file-name name server-socket-dir)))

(defun sprite-direct--parse-connection (target)
  "Parse TARGET into a connection plist.
TARGET is either a Unix socket name (e.g. \"work.0.render\") or a TCP
string \"HOST:PORT:KEY\".  Returns a plist with :type and :key at minimum."
  (or (sprite-direct--parse-tcp target)
      (list :type 'unix
            :name target
            :path (sprite-direct--socket-path target)
            :key (sprite-direct--read-auth-key target))))

;;;; Network process

(defun sprite-direct--filter (proc string)
  "Append STRING from PROC to the end of its process buffer."
  (when-let* ((buf (process-buffer proc)))
    (with-current-buffer buf
      (goto-char (point-max))
      (insert string))))

(defun sprite-direct--open (conn)
  "Open a network process described by CONN plist.
Returns the live process.  Signals an error and kills the buffer on failure."
  (let ((buf (generate-new-buffer " *sprite-direct*")))
    (condition-case err
        (pcase (map-elt conn :type)
          ('unix
           (make-network-process
            :name " sprite-direct"
            :buffer buf
            :filter #'sprite-direct--filter
            :family 'local
            :service (map-elt conn :path)
            :coding 'utf-8-unix
            :noquery t))
          ('tcp
           (make-network-process
            :name " sprite-direct"
            :buffer buf
            :filter #'sprite-direct--filter
            :host (map-elt conn :host)
            :service (map-elt conn :port)
            :coding 'utf-8-unix
            :noquery t))
          (type
           (user-error "sprite-direct: unknown connection type %S" type)))
      (error
       (kill-buffer buf)
       (signal (car err) (cdr err))))))

(defun sprite-direct--send (proc key form)
  "Send an eval request for FORM with auth KEY to PROC."
  (process-send-string
   proc
   (concat "-auth " key " -eval "
           (sprite-direct--encode (format "%S" form))
           " \n")))

(defun sprite-direct--parse-response (raw)
  "Parse the RAW server response string; return the read Lisp value or nil.
Searches for the first `-print VALUE' line and reads its decoded value.
Returns nil for `-error' responses, nil or unterminated RAW, unreadable
values, or when no recognised response line is found."
  (when (and raw (string-match-p "\n" raw))
    (catch 'done
      (seq-do
       (lambda (line)
         (cond
          ((string-match "^-print \\(.*\\)$" line)
           (throw 'done
                  (condition-case nil
                      (read (sprite-direct--decode (match-string 1 line)))
                    (error nil))))
          ((string-prefix-p "-error " line)
           (throw 'done nil))))
       (split-string raw "\n" t))
      nil)))

;;;; Connection context

(cl-defstruct (sprite-direct-conn
               (:constructor sprite-direct--conn-make)
               (:copier nil))
  "Context for sprite-direct operations.
Holds the parsed connection plist from `sprite-direct--parse-connection'.
Does not own a persistent socket; each operation opens a transient one."
  target   ; original target string (socket name or HOST:PORT:KEY)
  plist)   ; cached result of sprite-direct--parse-connection

(defun sprite-direct-open (target)
  "Return a `sprite-direct-conn' for TARGET.
TARGET is a Unix socket name (e.g. \"work.0.render\") or HOST:PORT:KEY.
Signals `user-error' immediately if no auth key can be found."
  (let ((plist (sprite-direct--parse-connection target)))
    (unless (map-elt plist :key)
      (user-error "sprite-direct: no auth key found for %S" target))
    (sprite-direct--conn-make :target target :plist plist)))

(cl-defmacro with-sprite-direct ((var target) &rest body)
  "Bind VAR to a connection context for TARGET and evaluate BODY.
Each operation in BODY opens a transient socket as needed.
TARGET is evaluated once; the conn is created by `sprite-direct-open'."
  (declare (indent 1))
  (let ((gconn (make-symbol "conn")))
    `(let* ((,gconn (sprite-direct-open ,target))
            (,var ,gconn))
       ,@body)))

;;;; Generator-based receive

(iter-defun sprite-direct--recv-gen (proc)
  "Generator that yields `:pending' until PROC's buffer contains a newline.
The final return value is the raw response string, or nil when PROC dies
before a complete response arrives."
  (while (and (process-live-p proc)
              (with-current-buffer (process-buffer proc)
                (not (string-match-p "\n" (buffer-string)))))
    (iter-yield :pending))
  (when-let* ((buf (process-buffer proc))
              ((buffer-live-p buf)))
    (with-current-buffer buf
      (buffer-string))))

(defun sprite-direct--await (gen &optional timeout proc)
  "Drive generator GEN to completion; return its final value.
Calls `accept-process-output' on each `:pending' yield, targeting PROC
when given (or any process when nil).  TIMEOUT overrides
`sprite-direct-blocking-timeout'; nil means block indefinitely.
Returns nil when the timeout expires before GEN produces a value."
  (let ((deadline (let ((limit (or timeout sprite-direct-blocking-timeout)))
                    (when limit (+ (float-time) limit)))))
    (catch 'done
      (while t
        (condition-case seq-val
            (when (eq :pending (iter-next gen))
              (when (and deadline (> (float-time) deadline))
                (iter-close gen)
                (throw 'done nil))
              (if proc
                  (accept-process-output proc sprite-direct-yield-interval nil t)
                (accept-process-output nil sprite-direct-yield-interval)))
          (iter-end-of-sequence
           (throw 'done (cdr seq-val))))))))

;;;; Blocking evaluation

(defun sprite-direct-eval-blocking (conn form &optional timeout)
  "Evaluate FORM in the sprite via CONN; return the Lisp value.
Opens a transient socket, sends the form, and blocks using the generator
receive loop.  TIMEOUT overrides `sprite-direct-blocking-timeout'.
Returns nil on connection failure or server error."
  (let* ((plist (sprite-direct-conn-plist conn))
         (key (map-elt plist :key))
         (proc (condition-case nil
                   (sprite-direct--open plist)
                 (error nil)))
         (buf (when proc (process-buffer proc))))
    (when proc
      (unwind-protect
          (progn
            (sprite-direct--send proc key form)
            (sprite-direct--parse-response
             (sprite-direct--await (sprite-direct--recv-gen proc) timeout proc)))
        (when (process-live-p proc)
          (delete-process proc))
        (when (buffer-live-p buf)
          (kill-buffer buf))))))

(defun sprite-direct-call-and-read (target form &optional timeout)
  "Evaluate FORM in the Emacs server at TARGET; return the read Lisp value.
Drop-in replacement for `sprite--call-and-read' in sprite.el.
TARGET is a Unix socket name or HOST:PORT:KEY TCP string.
TIMEOUT is passed to `sprite-direct-eval-blocking'.
Returns nil on connection failure, missing auth key, or server error."
  (condition-case nil
      (with-sprite-direct (conn target)
        (sprite-direct-eval-blocking conn form timeout))
    (user-error nil)))

;;;; Non-blocking evaluation (promise)

(defvar sprite-direct--op-counter 0
  "Monotonic counter for unique promise operation IDs.")

(defun sprite-direct--next-op-id ()
  "Return the next unique integer operation ID."
  (setq sprite-direct--op-counter (1+ sprite-direct--op-counter)))

(cl-defstruct (sprite-direct-promise
               (:constructor sprite-direct--promise-make)
               (:copier nil))
  "Result handle for a non-blocking sprite-direct evaluation.
`state' is one of :pending, :resolved, or :rejected.
`value' holds the Lisp result when :resolved, nil otherwise.
`result-buffer' is an optional buffer name where the result is appended."
  op-id          ; unique integer ID
  conn           ; originating sprite-direct-conn
  state          ; :pending :resolved :rejected
  value          ; Lisp result (nil until resolved)
  result-buffer  ; optional buffer name for result appending
  proc)          ; underlying transient network process

(defun sprite-direct--promise-sentinel (proc event)
  "Resolve the promise attached to PROC when the connection closes."
  (when (string-match-p "\\(?:finished\\|connection broken\\|deleted\\)" event)
    (when-let* ((promise (process-get proc 'sprite-direct-promise)))
      (let* ((raw (when-let* ((buf (process-buffer proc))
                              ((buffer-live-p buf)))
                    (with-current-buffer buf (buffer-string))))
             (value (when raw (sprite-direct--parse-response raw)))
             (result-buf (sprite-direct-promise-result-buffer promise)))
        (setf (sprite-direct-promise-state promise)
              (if (and raw (string-match-p "\n" raw)) :resolved :rejected)
              (sprite-direct-promise-value promise) value)
        (when (and result-buf value (get-buffer result-buf))
          (with-current-buffer result-buf
            (goto-char (point-max))
            (insert (format "%S\n" value))))
        (when-let* ((buf (process-buffer proc))
                    ((buffer-live-p buf)))
          (kill-buffer buf))))))

(defun sprite-direct-eval-non-blocking (conn form &optional result-buffer)
  "Evaluate FORM in CONN asynchronously; return a `sprite-direct-promise'.
The promise resolves when the server closes the connection (via sentinel).
RESULT-BUFFER is an optional buffer name; when the promise resolves, the
result is appended to it as a `prin1' line.  Returns the promise immediately.
If the connection cannot be opened, the promise is in :rejected state."
  (let* ((plist (sprite-direct-conn-plist conn))
         (key (map-elt plist :key))
         (op-id (sprite-direct--next-op-id))
         (proc (condition-case nil
                   (sprite-direct--open plist)
                 (error nil)))
         (promise (sprite-direct--promise-make
                   :op-id op-id
                   :conn conn
                   :state (if proc :pending :rejected)
                   :result-buffer result-buffer
                   :proc proc)))
    (when proc
      (process-put proc 'sprite-direct-promise promise)
      (set-process-sentinel proc #'sprite-direct--promise-sentinel)
      (sprite-direct--send proc key form))
    promise))

(defun sprite-direct-promise-pending-p (promise)
  "Return t when PROMISE has not yet resolved or been rejected."
  (eq :pending (sprite-direct-promise-state promise)))

(defun sprite-direct-promise-resolved-p (promise)
  "Return t when PROMISE resolved successfully."
  (eq :resolved (sprite-direct-promise-state promise)))

(defun sprite-direct-promise-wait (promise &optional timeout)
  "Block until PROMISE resolves; return its value or nil on timeout/rejection.
Drives process output while waiting.  TIMEOUT overrides
`sprite-direct-blocking-timeout'; nil means wait indefinitely."
  (let* ((proc (sprite-direct-promise-proc promise))
         (limit (or timeout sprite-direct-blocking-timeout))
         (deadline (when limit (+ (float-time) limit))))
    (while (and (sprite-direct-promise-pending-p promise)
                (or (null deadline) (< (float-time) deadline))
                (when proc (process-live-p proc)))
      (accept-process-output proc sprite-direct-async-check-interval nil t))
    (sprite-direct-promise-value promise)))

;;;; Helper operations

(defun sprite-direct-list-buffers (conn)
  "Return a list of buffer names in the sprite via CONN."
  (sprite-direct-eval-blocking conn '(mapcar #'buffer-name (buffer-list))))

(defun sprite-direct-insert-into-buffer (conn buf-name text &optional position)
  "Insert TEXT into BUF-NAME in the sprite via CONN.
When POSITION is non-nil, go there first; otherwise insert at `point-max'."
  (sprite-direct-eval-blocking
   conn
   `(with-current-buffer ,buf-name
      ,(if position
           `(progn (goto-char ,position) (insert ,text))
         `(progn (goto-char (point-max)) (insert ,text))))))

(cl-defmacro with-current-sprite-direct-buffer ((conn buf-name) &rest body)
  "Evaluate BODY forms in the sprite via CONN with BUF-NAME current.
BODY is literal Emacs Lisp sent verbatim to the sprite; local variables
are not in scope.  The result of the last BODY form is returned."
  (declare (indent 1))
  (let ((gconn (make-symbol "conn"))
        (gbuf (make-symbol "buf")))
    `(let ((,gconn ,conn)
           (,gbuf ,buf-name))
       (sprite-direct-eval-blocking
        ,gconn
        (append (list 'with-current-buffer ,gbuf) ',body)))))

(defun sprite-direct-read-buffer (conn buf-name &optional start end)
  "Return the contents of BUF-NAME in the sprite via CONN.
START and END are buffer positions (defaults: `point-min' and `point-max').
Returns a string, or nil on failure."
  (sprite-direct-eval-blocking
   conn
   `(with-current-buffer ,buf-name
      (buffer-substring-no-properties
       ,(or start '(point-min))
       ,(or end '(point-max))))))

(defun sprite-direct-value-of-symbol (conn symbol)
  "Return the value of SYMBOL in the sprite via CONN.
Evaluates `(symbol-value \\='SYMBOL)' in the sprite; returns nil on failure."
  (sprite-direct-eval-blocking conn `(symbol-value ',symbol)))

;;;; TCP server file utility

(defun sprite-direct-read-tcp-server-file (path)
  "Read the TCP server file at PATH; return its HOST:PORT:KEY string.
Returns nil when PATH is absent or unreadable."
  (when (file-readable-p path)
    (with-temp-buffer
      (insert-file-contents path)
      (string-trim (buffer-string)))))

(provide 'sprite-direct)
;;; sprite-direct.el ends here
