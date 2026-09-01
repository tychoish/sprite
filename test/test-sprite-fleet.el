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
  "`sprite-fleet-mapcar' with :async t returns a resolved sprite-future."
  (cl-letf (((symbol-function 'sprite-future-eval)
             (lambda (target form)
               (let ((f (sprite-future--make :target target :state :pending)))
                 (sprite-future--settle f :resolved (concat "done-" (cadr (cadr form))))
                 f))))
    (let ((future (sprite-fleet-mapcar 'identity '("a" "b") :sprites '("w0") :async t)))
      (should (sprite-future-p future))
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
(provide 'test-sprite-fleet)
;;; test-sprite-fleet.el ends here
