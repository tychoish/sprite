;;; test-sprite-fleet.el --- ERT tests for sprite-fleet.el -*- lexical-binding: t; no-byte-compile: t; -*-

;; Run inside a live Emacs session:
;;   (ert "^sprite-fleet/")
;;
;; Batch run:
;;   emacs --batch -L ~/.emacs.d/external/sprite \
;;     -l ~/.emacs.d/external/sprite/test/test-sprite-fleet.el \
;;     --eval '(ert-run-tests-batch-and-exit "sprite-fleet/")'

;;; Commentary:
;;
;; Unit tests for sprite-fleet.el.  `sprite-future-eval'/`sprite-future-wait'
;; are mocked throughout; no real sprites, transports, or daemons are needed.
;;

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'sprite)
(require 'sprite-fleet)

(defun sprite-fleet-test--sprite (name)
  "Return a minimal sprite struct named NAME for fleet tests."
  (sprite--make :name name :idx 0 :parent "work" :unique-name name))

;;;; sprite-fleet-mapcar-sprites

(ert-deftest sprite-fleet/mapcar-returns-results-in-order ()
  "`sprite-fleet-mapcar-sprites' returns one result per sprite, in input order."
  (cl-letf (((symbol-function 'sprite-future-eval)
             (lambda (target _form) (cons :future target)))
            ((symbol-function 'sprite-future-wait)
             (cl-function
              (lambda (future &key timeout)
                (pcase future (`(:future . ,target) (concat target "-result")))))))
    (let ((sprites (list (sprite-fleet-test--sprite "a")
                          (sprite-fleet-test--sprite "b")
                          (sprite-fleet-test--sprite "c"))))
      (should (equal '("a-result" "b-result" "c-result")
                     (sprite-fleet-mapcar-sprites '(ignore) sprites))))))

(ert-deftest sprite-fleet/mapcar-dispatches-all-before-waiting-any ()
  "`sprite-fleet-mapcar-sprites' launches every future before waiting on any of them."
  (let (events)
    (cl-letf (((symbol-function 'sprite-future-eval)
               (lambda (target _form) (push (cons :dispatch target) events) target))
              ((symbol-function 'sprite-future-wait)
               (cl-function (lambda (future &key timeout) (push (cons :wait future) events) future))))
      (sprite-fleet-mapcar-sprites '(ignore)
                      (list (sprite-fleet-test--sprite "a")
                            (sprite-fleet-test--sprite "b")))
      (setq events (nreverse events))
      (should (equal '((:dispatch . "a") (:dispatch . "b") (:wait . "a") (:wait . "b"))
                     events)))))

(ert-deftest sprite-fleet/mapcar-timeout-to-nil ()
  "A sprite whose future never settles contributes nil at its position."
  (cl-letf (((symbol-function 'sprite-future-eval) (lambda (target _form) target))
            ((symbol-function 'sprite-future-wait)
             (cl-function (lambda (future &key timeout) (unless (equal future "slow") future)))))
    (let ((sprites (list (sprite-fleet-test--sprite "fast")
                          (sprite-fleet-test--sprite "slow"))))
      (should (equal '("fast" nil) (sprite-fleet-mapcar-sprites '(ignore) sprites))))))

(ert-deftest sprite-fleet/mapcar-passes-timeout-through ()
  "`sprite-fleet-mapcar-sprites's TIMEOUT argument reaches `sprite-future-wait'."
  (let (seen-timeout)
    (cl-letf (((symbol-function 'sprite-future-eval) (lambda (target _form) target))
              ((symbol-function 'sprite-future-wait)
               (cl-function (lambda (_future &key timeout) (setq seen-timeout timeout)))))
      (sprite-fleet-mapcar-sprites '(ignore) (list (sprite-fleet-test--sprite "a")) :timeout 3.5)
      (should (= 3.5 seen-timeout)))))

(ert-deftest sprite-fleet/mapcar-empty-sprites-returns-nil ()
  (should (null (sprite-fleet-mapcar-sprites '(ignore) nil))))

;;;; sprite-fleet-mapc

(ert-deftest sprite-fleet/mapc-dispatches-to-every-sprite ()
  "`sprite-fleet-mapc' calls `sprite-future-eval' once per sprite."
  (let (dispatched)
    (cl-letf (((symbol-function 'sprite-future-eval)
               (lambda (target _form) (push target dispatched))))
      (sprite-fleet-mapc '(ignore) (list (sprite-fleet-test--sprite "a")
                                    (sprite-fleet-test--sprite "b")))
      (should (equal '("b" "a") dispatched)))))

(ert-deftest sprite-fleet/mapc-does-not-wait ()
  "`sprite-fleet-mapc' never calls `sprite-future-wait'."
  (let (waited)
    (cl-letf (((symbol-function 'sprite-future-eval) #'ignore)
              ((symbol-function 'sprite-future-wait) (lambda (&rest _) (setq waited t))))
      (sprite-fleet-mapc '(ignore) (list (sprite-fleet-test--sprite "a")))
      (should-not waited))))

(ert-deftest sprite-fleet/mapc-returns-sprites-unchanged ()
  (cl-letf (((symbol-function 'sprite-future-eval) #'ignore))
    (let ((sprites (list (sprite-fleet-test--sprite "a"))))
      (should (eq sprites (sprite-fleet-mapc '(ignore) sprites))))))

;;;; sprite-fleet-let

(ert-deftest sprite-fleet/let-binds-resolved-values ()
  "`sprite-fleet-let' binds each VAR to its FORM's resolved value."
  (cl-letf (((symbol-function 'sprite-future-eval)
             (lambda (target form) (list :future target form)))
            ((symbol-function 'sprite-future-wait)
             (cl-function
              (lambda (future &key timeout)
                (pcase future (`(:future ,_target ,form) (eval form t)))))))
    (should (= 3 (sprite-fleet-let ((x "work.0.a" (+ 1 2)))
                   x)))))

(ert-deftest sprite-fleet/let-dispatches-all-before-waiting-any ()
  "`sprite-fleet-let' launches every binding's future before waiting on any."
  (let (events)
    (cl-letf (((symbol-function 'sprite-future-eval)
               (lambda (target _form) (push (cons :dispatch target) events) target))
              ((symbol-function 'sprite-future-wait)
               (cl-function (lambda (future &key timeout) (push (cons :wait future) events) future))))
      (sprite-fleet-let ((x "a" (ignore))
                         (y "b" (ignore)))
        (list x y))
      (setq events (nreverse events))
      (should (equal '((:dispatch . "a") (:dispatch . "b") (:wait . "a") (:wait . "b"))
                     events)))))

(ert-deftest sprite-fleet/let-body-runs-once-after-all-settle ()
  "`sprite-fleet-let's BODY sees every binding already resolved."
  (cl-letf (((symbol-function 'sprite-future-eval) (lambda (target form) (cons target form)))
            ((symbol-function 'sprite-future-wait)
             (cl-function (lambda (future &key timeout) (cdr future)))))
    (should (equal '(1 . 2)
                   (sprite-fleet-let ((a "w.0.a" 1)
                                      (b "w.0.b" 2))
                     (cons a b))))))

;;;; sprite-fleet-mapcar

(ert-deftest sprite-fleet/fleet-mapcar-empty-returns-nil ()
  "`sprite-fleet-mapcar' with empty items returns nil."
  (should (null (sprite-fleet-mapcar #'identity nil))))

(ert-deftest sprite-fleet/fleet-mapcar-dispatches-items-over-fleet ()
  "`sprite-fleet-mapcar' dispatches items over given sprites and returns ordered results."
  (let ((dispatches nil))
    (cl-letf (((symbol-function 'sprite-future-eval)
               (lambda (target form)
                 (push (cons target form) dispatches)
                 (let ((f (sprite-future--make :target target :state :pending)))
                   (sprite-future--settle f :resolved (cadr (cadr form)))
                   f))))
      (let ((res (sprite-fleet-mapcar '1+ '(10 20 30) :sprites '("worker-0" "worker-1"))))
        (should (equal '(10 20 30) res))
        (should (= 3 (length dispatches)))))))

(ert-deftest sprite-fleet/fleet-mapcar-async-returns-future ()
  "`sprite-fleet-mapcar' with :async t returns a sprite-future."
  (cl-letf (((symbol-function 'sprite-future-eval)
             (lambda (target form)
               (let ((f (sprite-future--make :target target :state :pending)))
                 (sprite-future--settle f :resolved (concat "done-" (cadr (cadr form))))
                 f))))
    (let ((future (sprite-fleet-mapcar 'identity '("a" "b") :sprites '("w0") :async t)))
      (should (sprite-future-p future))
      (while (sprite-future-pending-p future)
        (sit-for 0.005))
      (should (sprite-future-resolved-p future))
      (should (equal '("done-a" "done-b") (sprite-future-value future))))))

(ert-deftest sprite-fleet/fleet-mapcar-item-form-eval ()
  "`sprite-fleet-mapcar' evaluates forms with `item' or `_'."
  (let ((dispatches nil))
    (cl-letf (((symbol-function 'sprite-future-eval)
               (lambda (target form)
                 (push (cons target form) dispatches)
                 (let ((f (sprite-future--make :target target :state :pending)))
                   (sprite-future--settle f :resolved (eval form))
                   f))))
      (let ((res (sprite-fleet-mapcar '(+ item 1) '(5 15) :sprites '("w0"))))
        (should (equal '(6 16) res))))))

;;;; Stepper engine, flow control, and combinators

(defmacro sprite-fleet-test-wait-until (predicate &optional timeout)
  "Wait until PREDICATE returns non-nil, or TIMEOUT seconds elapse."
  `(let ((start (float-time))
         (max-t (or ,timeout 2.0)))
     (while (and (not ,predicate)
                 (< (- (float-time) start) max-t))
       (sit-for 0.005))
     (should ,predicate)))

(ert-deftest sprite-fleet/stepper-engine-progress-tracking ()
  "`sprite-fleet-progress' reports completed and total count accurately."
  (let ((items '(1 2 3 4)))
    (cl-letf (((symbol-function 'sprite-future-eval)
               (lambda (target form)
                 (let ((f (sprite-future--make :target target :state :pending)))
                   (run-with-timer 0.01 nil
                                   (lambda ()
                                     (sprite-future--settle f :resolved (eval form))))
                   f))))
      (let* ((handle (sprite-fleet-pool '1+ items :sprites '("w1" "w2"))))
        (should (equal '(0 . 4) (sprite-fleet-progress handle)))
        (sprite-fleet-test-wait-until (sprite-fleet-completed-p handle))
        (should (equal '(4 . 4) (sprite-fleet-progress handle)))
        (should (equal '(2 3 4 5) (sprite-future-value (sprite-fleet-handle-future handle))))))))

(ert-deftest sprite-fleet/stepper-engine-pause-and-resume ()
  "`sprite-fleet-pause' freezes new dispatches; `sprite-fleet-resume' continues."
  (let ((dispatches nil)
        (callbacks nil))
    (cl-letf (((symbol-function 'sprite-future-eval)
               (lambda (target form)
                 (push (cons target form) dispatches)
                 (let ((f (sprite-future--make :target target :state :pending)))
                   (push (cons (cadr (cadr form)) f) callbacks)
                   f))))
      (let* ((handle (sprite-fleet-pool 'identity '(10 20 30 40)
                                        :sprites '("w1" "w2"))))
        ;; Wait until initial 2 workers are dispatched
        (sprite-fleet-test-wait-until (= (length dispatches) 2))
        (should (sprite-fleet-running-p handle))
        ;; Pause the handle
        (sprite-fleet-pause handle)
        (should (sprite-fleet-paused-p handle))
        ;; Settle first worker
        (let ((c1 (cdr (assq 10 callbacks))))
          (sprite-future--settle c1 :resolved 10))
        (sit-for 0.02)
        ;; No new workers should have been dispatched while paused
        (should (= (length dispatches) 2))
        ;; Settle second worker
        (let ((c2 (cdr (assq 20 callbacks))))
          (sprite-future--settle c2 :resolved 20))
        (sit-for 0.02)
        (should (= (length dispatches) 2))
        ;; Now resume
        (sprite-fleet-resume handle)
        (should (sprite-fleet-running-p handle))
        ;; Remaining 2 workers are dispatched
        (sprite-fleet-test-wait-until (= (length dispatches) 4))
        ;; Settle remaining workers
        (sprite-future--settle (cdr (assq 30 callbacks)) :resolved 30)
        (sprite-future--settle (cdr (assq 40 callbacks)) :resolved 40)
        (sprite-fleet-test-wait-until (sprite-fleet-completed-p handle))
        (should (equal '(10 20 30 40) (sprite-future-value (sprite-fleet-handle-future handle))))))))

(ert-deftest sprite-fleet/stepper-engine-cancel-aborts-scheduled-and-active ()
  "`sprite-fleet-cancel' stops execution, cancels in-flight workers, and rejects future."
  (let ((dispatches nil)
        (worker-futures nil))
    (cl-letf (((symbol-function 'sprite-future-eval)
               (lambda (target form)
                 (push (cons target form) dispatches)
                 (let ((f (sprite-future--make :target target :state :pending)))
                   (push f worker-futures)
                   f))))
      (let* ((handle (sprite-fleet-pool 'identity '(1 2 3 4 5 6)
                                        :sprites '("w1" "w2"))))
        (sprite-fleet-test-wait-until (= (length dispatches) 2))
        (sprite-fleet-cancel handle :user-requested-abort)
        (should (sprite-fleet-canceled-p handle))
        (should (sprite-future-rejected-p (sprite-fleet-handle-future handle)))
        (should (equal '(:canceled . :user-requested-abort)
                       (sprite-future-value (sprite-fleet-handle-future handle))))
        ;; All in-flight worker futures should be rejected as canceled
        (dolist (wf worker-futures)
          (should (sprite-future-rejected-p wf))
          (should (equal '(:canceled . :user-requested-abort)
                         (sprite-future-value wf))))
        (sit-for 0.02)
        ;; No further dispatches occurred
        (should (= (length dispatches) 2))))))

(ert-deftest sprite-fleet/stepper-engine-error-policy-collect-nil ()
  "`:error-policy :collect-nil' replaces rejected worker values with nil."
  (cl-letf (((symbol-function 'sprite-future-eval)
             (lambda (target form)
               (let ((f (sprite-future--make :target target :state :pending))
                     (item (cadr (cadr form))))
                 (run-with-timer 0.005 nil
                                 (lambda ()
                                   (if (= item 2)
                                       (sprite-future--settle f :rejected "boom")
                                     (sprite-future--settle f :resolved (* item 10)))))
                 f))))
    (let ((res (sprite-fleet-mapcar 'identity '(1 2 3)
                                    :sprites '("w1" "w2")
                                    :error-policy :collect-nil)))
      (should (equal '(10 nil 30) res)))))

(ert-deftest sprite-fleet/stepper-engine-error-policy-collect-error ()
  "`:error-policy :collect-error' stores error descriptors for failed items."
  (cl-letf (((symbol-function 'sprite-future-eval)
             (lambda (target form)
               (let ((f (sprite-future--make :target target :state :pending))
                     (item (cadr (cadr form))))
                 (run-with-timer 0.005 nil
                                 (lambda ()
                                   (if (= item 2)
                                       (sprite-future--settle f :rejected "fail-err")
                                     (sprite-future--settle f :resolved (* item 10)))))
                 f))))
    (let ((res (sprite-fleet-mapcar 'identity '(1 2 3)
                                    :sprites '("w1" "w2")
                                    :error-policy :collect-error)))
      (should (equal 10 (nth 0 res)))
      (should (equal '(:error "fail-err" :target "w2") (nth 1 res)))
      (should (equal 30 (nth 2 res))))))

(ert-deftest sprite-fleet/stepper-engine-error-policy-abort ()
  "`:error-policy :abort' cancels the fleet upon first worker failure."
  (cl-letf (((symbol-function 'sprite-future-eval)
             (lambda (target form)
               (let ((f (sprite-future--make :target target :state :pending))
                     (item (cadr (cadr form))))
                 (run-with-timer 0.005 nil
                                 (lambda ()
                                   (if (= item 2)
                                       (sprite-future--settle f :rejected "critical-failure")
                                     (sprite-future--settle f :resolved (* item 10)))))
                 f))))
    (let* ((future (sprite-fleet-map 'identity '(1 2 3 4)
                                     :sprites '("w1")
                                     :error-policy :abort)))
      (sprite-fleet-test-wait-until (sprite-future-rejected-p future))
      (should (equal :canceled (car (sprite-future-value future))))
      (should (equal '(:worker-failed "w1" "critical-failure")
                     (cdr (sprite-future-value future)))))))

(ert-deftest sprite-fleet/stepper-engine-order-fifo ()
  "`:order \='fifo' returns results in order of completion."
  (let ((callbacks nil))
    (cl-letf (((symbol-function 'sprite-future-eval)
               (lambda (target form)
                 (let ((f (sprite-future--make :target target :state :pending)))
                   (push (cons (cadr (cadr form)) f) callbacks)
                   f))))
      (let* ((handle (sprite-fleet-pool 'identity '(a b c)
                                        :sprites '("w1" "w2" "w3")
                                        :order 'fifo)))
        (sprite-fleet-test-wait-until (= (length callbacks) 3))
        ;; Settle out of order: b, then c, then a
        (sprite-future--settle (cdr (assq 'b callbacks)) :resolved "res-b")
        (sprite-future--settle (cdr (assq 'c callbacks)) :resolved "res-c")
        (sprite-future--settle (cdr (assq 'a callbacks)) :resolved "res-a")
        (sprite-fleet-test-wait-until (sprite-fleet-completed-p handle))
        (should (equal '("res-b" "res-c" "res-a")
                       (sprite-future-value (sprite-fleet-handle-future handle))))))))

(ert-deftest sprite-fleet/stepper-engine-order-lifo ()
  "`:order \='lifo' returns results in reverse order of completion."
  (let ((callbacks nil))
    (cl-letf (((symbol-function 'sprite-future-eval)
               (lambda (target form)
                 (let ((f (sprite-future--make :target target :state :pending)))
                   (push (cons (cadr (cadr form)) f) callbacks)
                   f))))
      (let* ((handle (sprite-fleet-pool 'identity '(a b c)
                                        :sprites '("w1" "w2" "w3")
                                        :order 'lifo)))
        (sprite-fleet-test-wait-until (= (length callbacks) 3))
        (sprite-future--settle (cdr (assq 'b callbacks)) :resolved "res-b")
        (sprite-future--settle (cdr (assq 'c callbacks)) :resolved "res-c")
        (sprite-future--settle (cdr (assq 'a callbacks)) :resolved "res-a")
        (sprite-fleet-test-wait-until (sprite-fleet-completed-p handle))
        (should (equal '("res-a" "res-c" "res-b")
                       (sprite-future-value (sprite-fleet-handle-future handle))))))))

(ert-deftest sprite-fleet/stepper-engine-lazy-vector ()
  "`sprite-fleet-map' accepts vectors as input sequences."
  (cl-letf (((symbol-function 'sprite-future-eval)
             (lambda (target form)
               (let ((f (sprite-future--make :target target :state :pending)))
                 (run-with-timer 0.005 nil
                                 (lambda ()
                                   (sprite-future--settle f :resolved (* (cadr (cadr form)) 2))))
                 f))))
    (let ((future (sprite-fleet-map 'identity [10 20 30] :sprites '("w1" "w2"))))
      (sprite-fleet-test-wait-until (sprite-future-resolved-p future))
      (should (equal '(20 40 60) (sprite-future-value future))))))

(ert-deftest sprite-fleet/stepper-engine-lazy-generator ()
  "`sprite-fleet-map' consumes generator iterators lazily."
  (cl-letf (((symbol-function 'sprite-future-eval)
             (lambda (target form)
               (let ((f (sprite-future--make :target target :state :pending)))
                 (run-with-timer 0.005 nil
                                 (lambda ()
                                   (sprite-future--settle f :resolved (concat "gen-" (cadr (cadr form))))))
                 f))))
    (let* ((gen (iter-make (iter-yield "x") (iter-yield "y") (iter-yield "z")))
           (future (sprite-fleet-map 'identity gen :sprites '("w1" "w2"))))
      (sprite-fleet-test-wait-until (sprite-future-resolved-p future))
      (should (equal '("gen-x" "gen-y" "gen-z") (sprite-future-value future))))))

(ert-deftest sprite-fleet/each-streams-items ()
  "`sprite-fleet-each' streams results via on-item callback and returns handle."
  (let ((streamed nil)
        (done-called nil))
    (cl-letf (((symbol-function 'sprite-future-eval)
               (lambda (target form)
                 (let ((f (sprite-future--make :target target :state :pending)))
                   (run-with-timer 0.005 nil
                                   (lambda ()
                                     (sprite-future--settle f :resolved (1+ (cadr (cadr form))))))
                   f))))
      (let ((handle (sprite-fleet-each 'identity '(1 2 3)
                                       :sprites '("w1")
                                       :on-item (lambda (item result idx)
                                                  (push (list item result idx) streamed))
                                       :on-done (lambda (_res) (setq done-called t)))))
        (should (sprite-fleet-handle-p handle))
        (sprite-fleet-test-wait-until done-called)
        (should (= 3 (length streamed)))
        (should (equal '((3 4 2) (2 3 1) (1 2 0)) streamed))))))

(ert-deftest sprite-fleet/future-cancel-severs-process ()
  "`sprite-future-cancel' calls `delete-process' on underlying backend handle."
  (let* ((proc (make-process :name "test-dummy-proc"
                             :command '("cat")
                             :buffer nil))
         (f (sprite-future--make :target "w0"
                                 :state :pending
                                 :backend-handle proc)))
    (should (process-live-p proc))
    (should (sprite-future-pending-p f))
    (sprite-future-cancel f :test-reason)
    (should (sprite-future-rejected-p f))
    (should (equal '(:canceled . :test-reason) (sprite-future-value f)))
    (should-not (process-live-p proc))))


(ert-deftest sprite-fleet/strict-validation-checks ()
  "Invalid arguments signal immediate type/value errors."
  ;; Invalid order
  (should-error (sprite-fleet-pool 'identity '(1 2) :sprites '("w1") :order 'invalid-order))
  ;; Invalid error-policy
  (should-error (sprite-fleet-pool 'identity '(1 2) :sprites '("w1") :error-policy :bad-policy))
  ;; Negative delay
  (should-error (sprite-fleet-pool 'identity '(1 2) :sprites '("w1") :delay -0.5)))

(ert-deftest sprite-fleet/weak-handle-lookup ()
  "`sprite-future-fleet-handle' resolves handle without future metadata slot."
  (let ((future (sprite-fleet-map 'identity '() :sprites '("w1"))))
    (should (sprite-future-p future))
    (let ((handle (sprite-future-fleet-handle future)))
      (should (sprite-fleet-handle-p handle))
      (should (eq (sprite-fleet-handle-future handle) future)))))

(provide 'test-sprite-fleet)
;;; test-sprite-fleet.el ends here
