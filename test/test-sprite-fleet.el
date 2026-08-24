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

;;;; sprite-mapcar

(ert-deftest sprite-fleet/mapcar-returns-results-in-order ()
  "`sprite-mapcar' returns one result per sprite, in input order."
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
                     (sprite-mapcar '(ignore) sprites))))))

(ert-deftest sprite-fleet/mapcar-dispatches-all-before-waiting-any ()
  "`sprite-mapcar' launches every future before waiting on any of them."
  (let (events)
    (cl-letf (((symbol-function 'sprite-future-eval)
               (lambda (target _form) (push (cons :dispatch target) events) target))
              ((symbol-function 'sprite-future-wait)
               (cl-function (lambda (future &key timeout) (push (cons :wait future) events) future))))
      (sprite-mapcar '(ignore)
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
      (should (equal '("fast" nil) (sprite-mapcar '(ignore) sprites))))))

(ert-deftest sprite-fleet/mapcar-passes-timeout-through ()
  "`sprite-mapcar's TIMEOUT argument reaches `sprite-future-wait'."
  (let (seen-timeout)
    (cl-letf (((symbol-function 'sprite-future-eval) (lambda (target _form) target))
              ((symbol-function 'sprite-future-wait)
               (cl-function (lambda (_future &key timeout) (setq seen-timeout timeout)))))
      (sprite-mapcar '(ignore) (list (sprite-fleet-test--sprite "a")) :timeout 3.5)
      (should (= 3.5 seen-timeout)))))

(ert-deftest sprite-fleet/mapcar-empty-sprites-returns-nil ()
  (should (null (sprite-mapcar '(ignore) nil))))

;;;; sprite-mapc

(ert-deftest sprite-fleet/mapc-dispatches-to-every-sprite ()
  "`sprite-mapc' calls `sprite-future-eval' once per sprite."
  (let (dispatched)
    (cl-letf (((symbol-function 'sprite-future-eval)
               (lambda (target _form) (push target dispatched))))
      (sprite-mapc '(ignore) (list (sprite-fleet-test--sprite "a")
                                    (sprite-fleet-test--sprite "b")))
      (should (equal '("b" "a") dispatched)))))

(ert-deftest sprite-fleet/mapc-does-not-wait ()
  "`sprite-mapc' never calls `sprite-future-wait'."
  (let (waited)
    (cl-letf (((symbol-function 'sprite-future-eval) #'ignore)
              ((symbol-function 'sprite-future-wait) (lambda (&rest _) (setq waited t))))
      (sprite-mapc '(ignore) (list (sprite-fleet-test--sprite "a")))
      (should-not waited))))

(ert-deftest sprite-fleet/mapc-returns-sprites-unchanged ()
  (cl-letf (((symbol-function 'sprite-future-eval) #'ignore))
    (let ((sprites (list (sprite-fleet-test--sprite "a"))))
      (should (eq sprites (sprite-mapc '(ignore) sprites))))))

;;;; sprite-let

(ert-deftest sprite-fleet/let-binds-resolved-values ()
  "`sprite-let' binds each VAR to its FORM's resolved value."
  (cl-letf (((symbol-function 'sprite-future-eval)
             (lambda (target form) (list :future target form)))
            ((symbol-function 'sprite-future-wait)
             (cl-function
              (lambda (future &key timeout)
                (pcase future (`(:future ,_target ,form) (eval form t)))))))
    (should (= 3 (sprite-let ((x "work.0.a" (+ 1 2)))
                   x)))))

(ert-deftest sprite-fleet/let-dispatches-all-before-waiting-any ()
  "`sprite-let' launches every binding's future before waiting on any."
  (let (events)
    (cl-letf (((symbol-function 'sprite-future-eval)
               (lambda (target _form) (push (cons :dispatch target) events) target))
              ((symbol-function 'sprite-future-wait)
               (cl-function (lambda (future &key timeout) (push (cons :wait future) events) future))))
      (sprite-let ((x "a" (ignore))
                   (y "b" (ignore)))
        (list x y))
      (setq events (nreverse events))
      (should (equal '((:dispatch . "a") (:dispatch . "b") (:wait . "a") (:wait . "b"))
                     events)))))

(ert-deftest sprite-fleet/let-body-runs-once-after-all-settle ()
  "`sprite-let's BODY sees every binding already resolved."
  (cl-letf (((symbol-function 'sprite-future-eval) (lambda (target form) (cons target form)))
            ((symbol-function 'sprite-future-wait)
             (cl-function (lambda (future &key timeout) (cdr future)))))
    (should (equal '(10 . 32)
                   (sprite-let ((a "s1" 10)
                                (b "s2" 32))
                     (cons a b))))))

(provide 'test-sprite-fleet)
;;; test-sprite-fleet.el ends here
