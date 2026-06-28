;;; test-sprite-direct-gen.el --- ERT tests for sprite-direct-gen.el -*- lexical-binding: t -*-

;; Run inside a live Emacs session:
;;   (ert "^sprite-direct-gen/")
;;
;; Batch run:
;;   emacs --batch -L ~/.emacs.d/external/sprite \
;;     -l ~/.emacs.d/external/sprite/test/test-sprite-direct-gen.el \
;;     --eval '(ert-run-tests-batch-and-exit "sprite-direct-gen/")'

;;; Commentary:
;;
;; Unit tests for sprite-direct-gen.el.  No live daemons or sockets are
;; required: generator behaviour is tested with `iter-lambda', promise
;; resolution is tested by directly manipulating struct fields, and
;; connection operations are tested by mocking `sprite-direct-eval-blocking'.
;;

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'generator)
(require 'map)
(require 'sprite-direct)

;; Declare server.el variables as special so let-bindings in tests are dynamic.
(defvar server-auth-dir)
(defvar server-socket-dir)

;;;; Helpers

(defmacro sprite-direct-gen-test/with-mock-conn (var &rest body)
  "Bind VAR to a mock `sprite-direct-conn' and evaluate BODY.
The conn's plist has :type unix, :path \"/tmp/test\", :key \"testkey\"."
  (declare (indent 1))
  `(let ((,var (sprite-direct--conn-make
                :target "work.0.render"
                :plist (list :type 'unix
                             :path "/tmp/test-socket"
                             :key "testkey"))))
     ,@body))

;;;; Connection struct

(ert-deftest sprite-direct-gen/conn-target ()
  "`sprite-direct-conn-target' returns the stored target string."
  (sprite-direct-gen-test/with-mock-conn conn
    (should (equal "work.0.render" (sprite-direct-conn-target conn)))))

(ert-deftest sprite-direct-gen/conn-plist-key ()
  "`sprite-direct-conn-plist' returns the cached connection plist."
  (sprite-direct-gen-test/with-mock-conn conn
    (should (equal "testkey" (map-elt (sprite-direct-conn-plist conn) :key)))))

(ert-deftest sprite-direct-gen/open-signals-without-auth ()
  "`sprite-direct-open' signals `user-error' when the auth key is unavailable."
  (cl-letf (((symbol-function 'sprite-direct--parse-connection)
              (lambda (_) (list :type 'unix :path "/tmp/x" :key nil))))
    (should-error (sprite-direct-open "no-such-sprite") :type 'user-error)))

(ert-deftest sprite-direct-gen/open-returns-conn-with-auth ()
  "`sprite-direct-open' returns a conn when the auth key is present."
  (cl-letf (((symbol-function 'sprite-direct--parse-connection)
              (lambda (_) (list :type 'unix :path "/tmp/x" :key "k"))))
    (let ((conn (sprite-direct-open "test")))
      (should (sprite-direct-conn-p conn))
      (should (equal "test" (sprite-direct-conn-target conn))))))

;;;; with-sprite-direct macro

(ert-deftest sprite-direct-gen/with-sprite-direct-binds-conn ()
  "`with-sprite-direct' binds the conn variable in the body."
  (cl-letf (((symbol-function 'sprite-direct-open)
              (lambda (target)
                (sprite-direct--conn-make :target target :plist (list :key "k")))))
    (with-sprite-direct (c "work.0.render")
      (should (sprite-direct-conn-p c))
      (should (equal "work.0.render" (sprite-direct-conn-target c))))))

(ert-deftest sprite-direct-gen/with-sprite-direct-evaluates-body ()
  "`with-sprite-direct' returns the value of the last body form."
  (cl-letf (((symbol-function 'sprite-direct-open)
              (lambda (_) (sprite-direct--conn-make :target "t" :plist (list :key "k")))))
    (should (= 42 (with-sprite-direct (_ "t") 42)))))

;;;; Generator / await

(ert-deftest sprite-direct-gen/await-immediate-value ()
  "`sprite-direct--await' returns the final value of a non-pending generator."
  (let ((gen (funcall (iter-lambda () "result"))))
    (should (equal "result" (sprite-direct--await gen)))))

(ert-deftest sprite-direct-gen/await-drives-through-pending ()
  "`sprite-direct--await' drives through :pending yields and returns the value."
  (let* ((steps 0)
         (gen (funcall (iter-lambda ()
                         (iter-yield :pending)
                         (iter-yield :pending)
                         (setq steps (1+ steps))
                         "done"))))
    (should (equal "done" (sprite-direct--await gen)))
    (should (= 1 steps))))

(ert-deftest sprite-direct-gen/await-nil-generator ()
  "`sprite-direct--await' handles a generator that returns nil immediately."
  (let ((gen (funcall (iter-lambda () nil))))
    (should-not (sprite-direct--await gen))))

(ert-deftest sprite-direct-gen/await-timeout-zero ()
  "`sprite-direct--await' returns nil when timeout is zero and gen is pending."
  (let ((gen (funcall (iter-lambda ()
                        (while t (iter-yield :pending))))))
    (should-not (sprite-direct--await gen 0))))

(ert-deftest sprite-direct-gen/await-respects-blocking-timeout ()
  "`sprite-direct-blocking-timeout' is used when timeout arg is nil."
  (let ((sprite-direct-blocking-timeout 0)
        (gen (funcall (iter-lambda ()
                        (while t (iter-yield :pending))))))
    (should-not (sprite-direct--await gen))))

(ert-deftest sprite-direct-gen/await-explicit-timeout-overrides-var ()
  "An explicit TIMEOUT arg overrides `sprite-direct-blocking-timeout'."
  (let ((sprite-direct-blocking-timeout 999)
        (gen (funcall (iter-lambda ()
                        (while t (iter-yield :pending))))))
    ;; explicit 0 should timeout immediately despite blocking-timeout=999
    (should-not (sprite-direct--await gen 0))))

;;;; Operation ID counter

(ert-deftest sprite-direct-gen/next-op-id-increments ()
  "`sprite-direct--next-op-id' returns strictly increasing integers."
  (let ((a (sprite-direct--next-op-id))
        (b (sprite-direct--next-op-id)))
    (should (integerp a))
    (should (integerp b))
    (should (= b (1+ a)))))

;;;; Promise struct

(ert-deftest sprite-direct-gen/promise-pending-p-true ()
  "`sprite-direct-promise-pending-p' is t when state is :pending."
  (let ((p (sprite-direct--promise-make :state :pending)))
    (should (sprite-direct-promise-pending-p p))))

(ert-deftest sprite-direct-gen/promise-pending-p-false-resolved ()
  "`sprite-direct-promise-pending-p' is nil when state is :resolved."
  (let ((p (sprite-direct--promise-make :state :resolved)))
    (should-not (sprite-direct-promise-pending-p p))))

(ert-deftest sprite-direct-gen/promise-pending-p-false-rejected ()
  "`sprite-direct-promise-pending-p' is nil when state is :rejected."
  (let ((p (sprite-direct--promise-make :state :rejected)))
    (should-not (sprite-direct-promise-pending-p p))))

(ert-deftest sprite-direct-gen/promise-resolved-p-true ()
  "`sprite-direct-promise-resolved-p' is t when state is :resolved."
  (let ((p (sprite-direct--promise-make :state :resolved)))
    (should (sprite-direct-promise-resolved-p p))))

(ert-deftest sprite-direct-gen/promise-resolved-p-false-pending ()
  "`sprite-direct-promise-resolved-p' is nil when state is :pending."
  (let ((p (sprite-direct--promise-make :state :pending)))
    (should-not (sprite-direct-promise-resolved-p p))))

(ert-deftest sprite-direct-gen/promise-value-after-resolve ()
  "`sprite-direct-promise-value' returns the stored value."
  (let ((p (sprite-direct--promise-make :state :resolved :value 42)))
    (should (= 42 (sprite-direct-promise-value p)))))

(ert-deftest sprite-direct-gen/promise-value-nil-pending ()
  "`sprite-direct-promise-value' is nil while pending."
  (let ((p (sprite-direct--promise-make :state :pending)))
    (should-not (sprite-direct-promise-value p))))

;;;; Promise sentinel

(ert-deftest sprite-direct-gen/promise-sentinel-resolves-on-finished ()
  "`sprite-direct--promise-sentinel' sets state to :resolved on finished."
  (let* ((buf (generate-new-buffer " *sdg-test*"))
         (promise (sprite-direct--promise-make :state :pending :proc nil))
         (proc (start-process "sdg-sentinel-test" buf "true")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (insert "-print 99\n"))
          (process-put proc 'sprite-direct-promise promise)
          (set-process-sentinel proc #'sprite-direct--promise-sentinel)
          (while (process-live-p proc)
            (accept-process-output proc 0.1))
          (accept-process-output nil 0.1)
          (should (sprite-direct-promise-resolved-p promise))
          (should (= 99 (sprite-direct-promise-value promise))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest sprite-direct-gen/promise-sentinel-resolves-to-result-buffer ()
  "`sprite-direct--promise-sentinel' appends the value to result-buffer."
  (let* ((result-buf (generate-new-buffer " *sdg-result-test*"))
         (proc-buf (generate-new-buffer " *sdg-proc-test*"))
         (promise (sprite-direct--promise-make
                   :state :pending
                   :result-buffer (buffer-name result-buf)))
         (fake-proc (start-process "sdg-result-test" proc-buf "true")))
    (unwind-protect
        (progn
          (with-current-buffer proc-buf
            (insert "-print (1&_2&_3)\n"))
          (process-put fake-proc 'sprite-direct-promise promise)
          (set-process-sentinel fake-proc #'sprite-direct--promise-sentinel)
          (while (process-live-p fake-proc)
            (accept-process-output fake-proc 0.1))
          (accept-process-output nil 0.1)
          (should (sprite-direct-promise-resolved-p promise))
          (should (equal '(1 2 3) (sprite-direct-promise-value promise)))
          (with-current-buffer result-buf
            (should (string-match-p "(1 2 3)" (buffer-string)))))
      (when (buffer-live-p result-buf) (kill-buffer result-buf))
      (when (buffer-live-p proc-buf) (kill-buffer proc-buf)))))

;;;; promise-wait

(ert-deftest sprite-direct-gen/promise-wait-already-resolved ()
  "`sprite-direct-promise-wait' returns immediately for an already-resolved promise."
  (let ((p (sprite-direct--promise-make :state :resolved :value 7 :proc nil)))
    (should (= 7 (sprite-direct-promise-wait p)))))

(ert-deftest sprite-direct-gen/promise-wait-already-rejected ()
  "`sprite-direct-promise-wait' returns nil for an already-rejected promise."
  (let ((p (sprite-direct--promise-make :state :rejected :value nil :proc nil)))
    (should-not (sprite-direct-promise-wait p))))

;;;; Helper function form construction

(ert-deftest sprite-direct-gen/list-buffers-sends-correct-form ()
  "`sprite-direct-list-buffers' evaluates the buffer-name form in the sprite."
  (sprite-direct-gen-test/with-mock-conn conn
    (cl-letf (((symbol-function 'sprite-direct-eval-blocking)
                (lambda (c form &optional _timeout)
                  (and (eq c conn)
                       (equal '(mapcar #'buffer-name (buffer-list)) form)))))
      (sprite-direct-list-buffers conn))))

(ert-deftest sprite-direct-gen/insert-into-buffer-end-form ()
  "`sprite-direct-insert-into-buffer' inserts at point-max when position is nil."
  (sprite-direct-gen-test/with-mock-conn conn
    (let (captured)
      (cl-letf (((symbol-function 'sprite-direct-eval-blocking)
                  (lambda (_c form &optional _t)
                    (setq captured form))))
        (sprite-direct-insert-into-buffer conn "mybuf" "hello" nil))
      (should (equal 'with-current-buffer (car captured)))
      (should (equal "mybuf" (cadr captured)))
      ;; body is (progn (goto-char (point-max)) (insert "hello"))
      (let ((body (caddr captured)))
        (should (eq 'progn (car body)))
        (should (member '(insert "hello") (cdr body)))))))

(ert-deftest sprite-direct-gen/insert-into-buffer-position-form ()
  "`sprite-direct-insert-into-buffer' inserts at the given position."
  (sprite-direct-gen-test/with-mock-conn conn
    (let (captured)
      (cl-letf (((symbol-function 'sprite-direct-eval-blocking)
                  (lambda (_c form &optional _t)
                    (setq captured form))))
        (sprite-direct-insert-into-buffer conn "mybuf" "hi" 10))
      (should (member 10 (flatten-list captured))))))

(ert-deftest sprite-direct-gen/read-buffer-default-range ()
  "`sprite-direct-read-buffer' uses point-min/point-max by default."
  (sprite-direct-gen-test/with-mock-conn conn
    (let (captured)
      (cl-letf (((symbol-function 'sprite-direct-eval-blocking)
                  (lambda (_c form &optional _t)
                    (setq captured form))))
        (sprite-direct-read-buffer conn "mybuf"))
      ;; body is (buffer-substring-no-properties (point-min) (point-max))
      (let ((bsn (caddr captured)))
        (should (eq 'buffer-substring-no-properties (car bsn)))
        (should (member '(point-min) (cdr bsn)))
        (should (member '(point-max) (cdr bsn)))))))

(ert-deftest sprite-direct-gen/read-buffer-explicit-range ()
  "`sprite-direct-read-buffer' passes explicit START and END positions."
  (sprite-direct-gen-test/with-mock-conn conn
    (let (captured)
      (cl-letf (((symbol-function 'sprite-direct-eval-blocking)
                  (lambda (_c form &optional _t)
                    (setq captured form))))
        (sprite-direct-read-buffer conn "mybuf" 5 50))
      (should (member 5 (flatten-list captured)))
      (should (member 50 (flatten-list captured))))))

(ert-deftest sprite-direct-gen/value-of-symbol-form ()
  "`sprite-direct-value-of-symbol' sends the correct symbol-value form."
  (sprite-direct-gen-test/with-mock-conn conn
    (let (captured)
      (cl-letf (((symbol-function 'sprite-direct-eval-blocking)
                  (lambda (_c form &optional _t)
                    (setq captured form))))
        (sprite-direct-value-of-symbol conn 'my-var))
      (should (equal '(symbol-value 'my-var) captured)))))

;;;; with-current-sprite-direct-buffer macro

(ert-deftest sprite-direct-gen/with-current-sprite-direct-buffer-form ()
  "`with-current-sprite-direct-buffer' wraps body in with-current-buffer."
  (sprite-direct-gen-test/with-mock-conn conn
    (let (captured)
      (cl-letf (((symbol-function 'sprite-direct-eval-blocking)
                  (lambda (_c form &optional _t)
                    (setq captured form))))
        (with-current-sprite-direct-buffer (conn "test-buf")
          (insert "hello")
          (point-max)))
      (should (equal 'with-current-buffer (car captured)))
      (should (equal "test-buf" (cadr captured)))
      (should (member '(insert "hello") (cddr captured)))
      (should (member '(point-max) (cddr captured))))))

(ert-deftest sprite-direct-gen/with-current-sprite-direct-buffer-splices-buffer-name ()
  "Buffer name expression is evaluated; result is spliced into form."
  (sprite-direct-gen-test/with-mock-conn conn
    (let ((buf-name "dynamic-buf")
          captured)
      (cl-letf (((symbol-function 'sprite-direct-eval-blocking)
                  (lambda (_c form &optional _t)
                    (setq captured form))))
        (with-current-sprite-direct-buffer (conn buf-name)
          (point)))
      (should (equal "dynamic-buf" (cadr captured))))))

(provide 'test-sprite-direct-gen)
;;; test-sprite-direct-gen.el ends here
