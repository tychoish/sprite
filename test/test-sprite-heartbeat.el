;;; test-sprite-heartbeat.el --- ERT tests for sprite-heartbeat.el -*- lexical-binding: t -*-

;; Run inside a live Emacs session:
;;   (ert "^sprite-heartbeat/")

;;; Code:

(require 'ert)
(require 'map)
(require 'sprite)
(require 'sprite-heartbeat)

(setq sprite-instance-id "work")

;;;; sprite--record-heartbeat

(ert-deftest sprite-heartbeat/record-updates-last-contact ()
  "`sprite--record-heartbeat' sets last-contact on a registered sprite."
  (let ((sprite--registry (make-hash-table :test #'equal)))
    (sprite--registry-put (sprite--make :name "work.0.render" :idx 0
                                        :parent "work" :unique-name "render"))
    (sprite--record-heartbeat "work.0.render")
    (should (sprite-last-contact (sprite--registry-get "work.0.render")))))

(ert-deftest sprite-heartbeat/record-no-op-for-unknown-sprite ()
  "`sprite--record-heartbeat' is silent when the sprite is not in the registry."
  (let ((sprite--registry (make-hash-table :test #'equal)))
    (sprite--record-heartbeat "work.99.ghost")
    (should (= 0 (hash-table-count sprite--registry)))))

(ert-deftest sprite-heartbeat/record-updates-timestamp-to-now ()
  "The timestamp written by `sprite--record-heartbeat' is current."
  (let ((sprite--registry (make-hash-table :test #'equal))
        (before (current-time)))
    (sprite--registry-put (sprite--make :name "work.0.r" :idx 0
                                        :parent "work" :unique-name "r"))
    (sprite--record-heartbeat "work.0.r")
    (let ((contact (sprite-last-contact (sprite--registry-get "work.0.r"))))
      (should (not (time-less-p contact before))))))

;;;; sprite-parent-socket-name

(ert-deftest sprite-heartbeat/parent-socket-from-full-name ()
  "`sprite-parent-socket-name' extracts the parent component of a full name."
  (let ((sprite-instance-id "primary.0.worker"))
    (should (equal "primary" (sprite-parent-socket-name)))))

(ert-deftest sprite-heartbeat/parent-socket-falls-back-to-self ()
  "When the instance name is not a full sprite name, the instance itself is returned."
  (let ((sprite-instance-id "solo"))
    (should (equal "solo" (sprite-parent-socket-name)))))

;;;; sprite-defhandler

(ert-deftest sprite-heartbeat/defhandler-defines-a-function ()
  "`sprite-defhandler' produces a callable function."
  (sprite-defhandler sprite-test--echo-handler (caller msg)
    (format "%s: %s" caller msg))
  (should (fboundp 'sprite-test--echo-handler)))

(ert-deftest sprite-heartbeat/defhandler-updates-last-contact ()
  "The function defined by `sprite-defhandler' calls `sprite--record-heartbeat'."
  (let ((sprite--registry (make-hash-table :test #'equal)))
    (sprite--registry-put (sprite--make :name "work.0.r" :idx 0
                                        :parent "work" :unique-name "r"))
    (sprite-defhandler sprite-test--ping-handler (caller)
      t)
    (sprite-test--ping-handler "work.0.r")
    (should (sprite-last-contact (sprite--registry-get "work.0.r")))))

(ert-deftest sprite-heartbeat/defhandler-executes-body ()
  "The body of a `sprite-defhandler' form is evaluated and its value returned."
  (sprite-defhandler sprite-test--add-handler (caller a b)
    (+ a b))
  (let ((sprite--registry (make-hash-table :test #'equal)))
    (sprite--registry-put (sprite--make :name "work.0.r" :idx 0
                                        :parent "work" :unique-name "r"))
    (should (= 7 (sprite-test--add-handler "work.0.r" 3 4)))))

(provide 'test-sprite-heartbeat)
;;; test-sprite-heartbeat.el ends here
