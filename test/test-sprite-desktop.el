;;; test-sprite-desktop.el --- Tests for staged desktop restore -*- lexical-binding: t; -*-

;;; Commentary:
;; Unit tests for staged asynchronous desktop restore:
;; collector, classifier, scorer, lanes, pop order, await, save round-trip,
;; error handling, history, and the generic open-files API.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'desktop)
(require 'sprite-desktop)

(ert-deftest sprite-desktop/registers-savehist-history ()
  "Desktop lifecycle installs and removes hooks and registers history once."
  (let ((savehist-additional-variables nil)
        (savehist-mode-hook nil)
        (desktop-save-hook nil))
    (unwind-protect
        (progn
          (sprite-desktop--enable-hooks)
          (run-hooks 'savehist-mode-hook)
          (should (memq #'sprite-desktop--record-visits desktop-save-hook))
          (should (memq #'sprite-desktop--save-pending desktop-save-hook))
          (should (= 1 (seq-count (lambda (it) (eq it 'sprite-desktop-visit-history))
                                  savehist-additional-variables)))
          (should (= 1 (seq-count (lambda (it) (eq it 'sprite-desktop-cost-history))
                                  savehist-additional-variables))))
      (sprite-desktop--disable-hooks))
    (should-not (memq #'sprite-desktop--register-history savehist-mode-hook))
    (should-not (memq #'sprite-desktop--record-visits desktop-save-hook))
    (should-not (memq #'sprite-desktop--save-pending desktop-save-hook))))

(defvar eglox-activate-queue nil)

(defmacro sprite-desktop-test/with-env (&rest body)
  "Run BODY in an isolated staged desktop environment."
  (declare (indent 0) (debug t))
  `(let ((sprite-desktop--queue nil)
         (sprite-desktop--index (make-hash-table :test #'equal))
         (sprite-desktop-visit-history nil)
         (sprite-desktop-cost-history nil)
         (sprite-desktop--total-count 0)
         (sprite-desktop--completed-count 0)
         (sprite-desktop--failed-count 0)
         (sprite-desktop--cancel-fn nil)
         (sprite-desktop--paused nil)
         (sprite-desktop--last-log-time 0.0)
         (desktop-first-buffer nil)
         (noninteractive nil))
     (unwind-protect
         (progn ,@body)
       (sprite-desktop--disable-await)
       (when sprite-desktop--cancel-fn
         (funcall sprite-desktop--cancel-fn)
         (setq sprite-desktop--cancel-fn nil)))))

(ert-deftest sprite-desktop/record-visits-trims-history ()
  "Discard old visits and cap retained history at 2000 entries."
  (let* ((now (float-time))
         (sprite-desktop-cold-window 100)
         (sprite-desktop-visit-history
          (cons (cons "old" (- now 500))
                (seq-map (lambda (n) (cons (number-to-string n) now))
                         (number-sequence 1 2001)))))
    (cl-letf (((symbol-function 'buffer-list) (lambda (&rest _) nil)))
      (sprite-desktop--record-visits))
    (should (= (length sprite-desktop-visit-history) 2000))
    (should-not (assoc "old" sprite-desktop-visit-history))
    (should (assoc "1" sprite-desktop-visit-history))
    (should-not (assoc "2001" sprite-desktop-visit-history))))

(ert-deftest sprite-desktop/classifier-rules ()
  "Hot, light, heavy, cold assigned per the classification rules."
  (sprite-desktop-test/with-env
    (let* ((now (float-time))
           ;; Set history: file-hot visited 1 hour ago, file-cold visited 20 days ago
           (sprite-desktop-visit-history
            `((,(file-truename "/proj/hot.el") . ,(- now 3600.0))
              (,(file-truename "/proj/cold.el") . ,(- now (* 20 86400.0)))
              (,(file-truename "/proj/light.el") . ,(- now (* 2 86400.0)))
              (,(file-truename "/proj/heavy.el") . ,(- now (* 2 86400.0)))))
           (sprite-desktop-hot-window 86400.0)
           (sprite-desktop-cold-window 1209600.0)
           (sprite-desktop-heavy-ms 50))
      (cl-letf (((symbol-function 'sprite-desktop--active-project) (lambda () "/active-proj/"))
                ((symbol-function 'sprite-desktop--lsp-applicable-p)
                 (lambda (mode &optional _) (eq mode 'go-ts-mode))))
        ;; 1. In active project -> hot
        (let ((e (make-sprite-desktop-entry :file "/active-proj/foo.el" :project "/active-proj/" :mode 'emacs-lisp-mode :est-ms 10)))
          (should (eq (sprite-desktop--classify e) 'hot)))
        ;; 2. Visited within hot window -> hot
        (let ((e (make-sprite-desktop-entry :file (file-truename "/proj/hot.el") :project "/other/" :mode 'emacs-lisp-mode :est-ms 10)))
          (should (eq (sprite-desktop--classify e) 'hot)))
        ;; 3. No history -> cold
        (let ((e (make-sprite-desktop-entry :file "/unknown/file.el" :project "/other/" :mode 'emacs-lisp-mode :est-ms 10)))
          (should (eq (sprite-desktop--classify e) 'cold)))
        ;; 4. Older than cold window -> cold
        (let ((e (make-sprite-desktop-entry :file (file-truename "/proj/cold.el") :project "/other/" :mode 'emacs-lisp-mode :est-ms 10)))
          (should (eq (sprite-desktop--classify e) 'cold)))
        ;; 5. LSP applies -> heavy
        (let ((e (make-sprite-desktop-entry :file (file-truename "/proj/heavy.el") :project "/other/" :mode 'go-ts-mode :est-ms 10)))
          (should (eq (sprite-desktop--classify e) 'heavy)))
        ;; 6. Cost > heavy-ms -> heavy
        (let ((e (make-sprite-desktop-entry :file (file-truename "/proj/heavy.el") :project "/other/" :mode 'emacs-lisp-mode :est-ms 100)))
          (should (eq (sprite-desktop--classify e) 'heavy)))
        ;; 7. Otherwise -> light
        (let ((e (make-sprite-desktop-entry :file (file-truename "/proj/light.el") :project "/other/" :mode 'emacs-lisp-mode :est-ms 10)))
          (should (eq (sprite-desktop--classify e) 'light)))))))

(ert-deftest sprite-desktop/scorer-directions ()
  "Recency, project, and cost move score in the expected direction."
  (sprite-desktop-test/with-env
    (let* ((now (float-time))
           (sprite-desktop-visit-history
            `((,(file-truename "/recent.el") . ,(- now 60.0))
              (,(file-truename "/old.el") . ,(- now 36000.0)))))
      (cl-letf (((symbol-function 'sprite-desktop--active-project) (lambda () "/active/")))
        (let ((recent (make-sprite-desktop-entry :file (file-truename "/recent.el") :est-ms 10))
              (old (make-sprite-desktop-entry :file (file-truename "/old.el") :est-ms 10)))
          ;; More recent gets higher score
          (should (> (sprite-desktop--score recent) (sprite-desktop--score old))))
        (let ((in-proj (make-sprite-desktop-entry :project "/active/" :est-ms 10))
              (out-proj (make-sprite-desktop-entry :project "/other/" :est-ms 10)))
          ;; Active project gets higher score
          (should (> (sprite-desktop--score in-proj) (sprite-desktop--score out-proj))))
        (let ((cheap (make-sprite-desktop-entry :est-ms 5))
              (costly (make-sprite-desktop-entry :est-ms 150)))
          ;; Lower cost gets higher score (less penalty)
          (should (> (sprite-desktop--score cheap) (sprite-desktop--score costly))))))))

(ert-deftest sprite-desktop/pop-order-strict-priority ()
  "Strict lane priority: now, hot, light, heavy, cold, and best score first within lane."
  (sprite-desktop-test/with-env
    (let ((e-cold (make-sprite-desktop-entry :name "cold" :lane 'cold :score 100.0))
          (e-heavy (make-sprite-desktop-entry :name "heavy" :lane 'heavy :score 10.0))
          (e-light-low (make-sprite-desktop-entry :name "light-low" :lane 'light :score 5.0))
          (e-light-high (make-sprite-desktop-entry :name "light-high" :lane 'light :score 50.0))
          (e-hot (make-sprite-desktop-entry :name "hot" :lane 'hot :score 1.0)))
      (setf (alist-get 'cold sprite-desktop--queue) (list e-cold)
            (alist-get 'heavy sprite-desktop--queue) (list e-heavy)
            (alist-get 'light sprite-desktop--queue) (list e-light-high e-light-low)
            (alist-get 'hot sprite-desktop--queue) (list e-hot))
      ;; Pop order must be: hot, light-high, light-low, heavy, cold
      (should (eq (sprite-desktop--pop) e-hot))
      (should (eq (sprite-desktop--pop) e-light-high))
      (should (eq (sprite-desktop--pop) e-light-low))
      (should (eq (sprite-desktop--pop) e-heavy))
      (should (eq (sprite-desktop--pop) e-cold))
      (should (null (sprite-desktop--pop))))))

(ert-deftest sprite-desktop/bump-pops-next ()
  "A bumped entry pops next regardless of its original lane."
  (sprite-desktop-test/with-env
    (let ((e-hot (make-sprite-desktop-entry :name "hot" :lane 'hot :score 10.0))
          (e-cold (make-sprite-desktop-entry :name "cold" :lane 'cold :score 1.0)))
      (setf (alist-get 'hot sprite-desktop--queue) (list e-hot)
            (alist-get 'cold sprite-desktop--queue) (list e-cold))
      ;; Bump cold entry
      (sprite-desktop-bump e-cold)
      (should (eq (sprite-desktop-entry-lane e-cold) 'now))
      (should (eq (sprite-desktop--pop) e-cold))
      (should (eq (sprite-desktop--pop) e-hot))
      (should (null (sprite-desktop--pop))))))

(ert-deftest sprite-desktop/find-file-noselect-await ()
  "Visiting a pending file materializes it immediately and clears it from queue."
  (sprite-desktop-test/with-env
    (let* ((temp-file (make-temp-file "staged-await-"))
           (truename (file-truename temp-file)))
      (write-region "1234567890\n" nil temp-file)
      (let* ((args (list 208 temp-file "staged-await-buf" 'text-mode nil 5 nil nil nil))
             (entry (sprite-desktop-enqueue args :file truename)))
      (should entry)
      (should (gethash truename sprite-desktop--index))
      (unwind-protect
          (let ((buf (find-file-noselect temp-file)))
            (should (buffer-live-p buf))
            (with-current-buffer buf
              (should (= (point) 5)))
            ;; Entry should no longer be indexed
            (should-not (gethash truename sprite-desktop--index))
            (should (eq (sprite-desktop-entry-state entry) 'done))
            (kill-buffer buf))
        (delete-file temp-file))))))

(ert-deftest sprite-desktop/find-file-noselect-unrelated ()
  "Visiting an unqueued file proceeds normally without touching queue."
  (sprite-desktop-test/with-env
    (let* ((temp-queued (make-temp-file "staged-q-"))
           (temp-other (make-temp-file "staged-other-"))
           (args (list 208 temp-queued "staged-q" 'text-mode nil 1 nil nil nil)))
      (sprite-desktop-enqueue args :file (file-truename temp-queued))
      (unwind-protect
          (let ((buf (find-file-noselect temp-other)))
            (should (buffer-live-p buf))
            ;; Queued file is still pending in index
            (should (gethash (file-truename temp-queued) sprite-desktop--index))
            (kill-buffer buf))
        (delete-file temp-queued)
        (delete-file temp-other)))))

(ert-deftest sprite-desktop/stage-and-collector ()
  "Collector restores eager set immediately and enqueues remainder."
  (sprite-desktop-test/with-env
    (let* ((sprite-desktop-eager-count 2)
           (eager-restored 0)
           (fake-entries
            (list (list 208 "/f1" "f1" 'text-mode nil 1 nil nil nil)
                  (list 208 "/f2" "f2" 'text-mode nil 1 nil nil nil)
                  (list 208 "/f3" "f3" 'text-mode nil 1 nil nil nil)
                  (list 208 "/f4" "f4" 'text-mode nil 1 nil nil nil))))
      (cl-letf (((symbol-function 'desktop-create-buffer)
                 (lambda (&rest _)
                   (cl-incf eager-restored)
                   (generate-new-buffer "fake")))
                ((symbol-function 'sprite-desktop--start-drain) #'ignore))
        (sprite-desktop--stage fake-entries)
        (should (= eager-restored 2))
        (should (= (length (sprite-desktop--pending-entries)) 2))))))

(ert-deftest sprite-desktop/save-roundtrip-preserves-pending ()
  "Saving while pending writes sprite-desktop--restore-entry forms."
  (sprite-desktop-test/with-env
    (let* ((entry (make-sprite-desktop-entry
                   :args '(208 "/pending.txt" "pending" text-mode nil 1 nil nil nil)
                   :lane 'light
                   :state 'pending)))
      (push entry (alist-get 'light sprite-desktop--queue))
      (with-temp-buffer
        (sprite-desktop--save-pending)
        (should (string-search "sprite-desktop--restore-entry" (buffer-string)))
        (should (string-search "/pending.txt" (buffer-string)))))))

(ert-deftest sprite-desktop/restore-entry-fallback ()
  "sprite-desktop--restore-entry falls back to desktop-append-buffer-args when not staged."
  (let ((appended nil))
    (cl-letf (((symbol-function 'desktop-append-buffer-args)
               (lambda (&rest args) (setq appended args))))
      (sprite-desktop--restore-entry '(208 "/fallback.txt"))
      (should (equal appended '(208 "/fallback.txt"))))))

(ert-deftest sprite-desktop/history-updates ()
  "Cost and visit history update properly."
  (sprite-desktop-test/with-env
    (setq sprite-desktop-cost-sample-weight 0.5)
    (sprite-desktop--record-cost 'emacs-lisp-mode 10.0)
    (should (= (alist-get 'emacs-lisp-mode sprite-desktop-cost-history) 10.0))
    ;; Update with new sample 20.0: (+ (* 0.5 20) (* 0.5 10)) = 15.0
    (sprite-desktop--record-cost 'emacs-lisp-mode 20.0)
    (should (= (alist-get 'emacs-lisp-mode sprite-desktop-cost-history) 15.0))))

(ert-deftest sprite-desktop/pause-and-resume ()
  "Pausing stops drain and resuming restarts drain."
  (sprite-desktop-test/with-env
    (let ((drain-started nil)
          (cancelled nil))
      (setq sprite-desktop--cancel-fn (lambda () (setq cancelled t)))
      (cl-letf (((symbol-function 'sprite-desktop--start-drain)
                 (lambda () (setq drain-started t))))
        (sprite-desktop-pause)
        (should (eq sprite-desktop--paused t))
        (should (eq cancelled t))
        (should-not sprite-desktop--cancel-fn)
        (sprite-desktop-resume)
        (should-not sprite-desktop--paused)
        (should (eq drain-started t))))))

(ert-deftest sprite-desktop/open-files-api ()
  "sprite-desktop-open-files enqueues files."
  (sprite-desktop-test/with-env
    (let* ((f1 (make-temp-file "bulk-1-"))
           (f2 (make-temp-file "bulk-2-")))
      (unwind-protect
          (cl-letf (((symbol-function 'sprite-desktop--start-drain) #'ignore))
            (sprite-desktop-open-files (list f1 f2) :project "/test-bulk/")
            (should (gethash (file-truename f1) sprite-desktop--index))
            (should (gethash (file-truename f2) sprite-desktop--index))
            (should (= (length (sprite-desktop--pending-entries)) 2)))
        (delete-file f1)
        (delete-file f2)))))

(ert-deftest sprite-desktop/materialize-error-handling ()
  "Errors during materialization mark entry as failed without aborting."
  (sprite-desktop-test/with-env
    (let ((entry (make-sprite-desktop-entry
                  :args '(208 "/nonexistent/path/foo.txt" "foo" text-mode nil 1 nil nil nil)
                  :file "/nonexistent/path/foo.txt"
                  :lane 'light
                  :state 'pending)))
      (push entry (alist-get 'light sprite-desktop--queue))
      (puthash "/nonexistent/path/foo.txt" entry sprite-desktop--index)
      (cl-letf (((symbol-function 'desktop-create-buffer)
                 (lambda (&rest _) (error "Simulated read error"))))
        (let ((result (sprite-desktop--materialize entry)))
          (should (null result))
          (should (eq (sprite-desktop-entry-state entry) 'failed))
          (should (= sprite-desktop--failed-count 1))
          (should (= sprite-desktop--completed-count 1)))))))

(ert-deftest sprite-desktop/read-skips-missing-files ()
  "sprite-desktop-read drops missing files before staging."
  (sprite-desktop-test/with-env
    (let ((existing (make-temp-file "staged-existing-"))
          (missing "/tmp/sprite-desktop-definitely-missing-file.el")
          (sprite-desktop-eager-count 1)
          (messages nil))
      (unwind-protect
          (cl-letf (((symbol-function 'desktop-read)
                     (lambda (&rest _)
                       (desktop-create-buffer 208 missing "missing" 'text-mode nil 1 nil nil nil)
                       (desktop-create-buffer 208 existing "existing" 'text-mode nil 1 nil nil nil)
                       t))
                    ((symbol-function 'sprite-desktop--start-drain) #'ignore)
                    ((symbol-function 'message)
                     (lambda (fmt &rest args)
                       (push (apply #'format fmt args) messages))))
            (should (eq t (sprite-desktop-read "/tmp")))
            (should (= sprite-desktop--total-count 1))
            (should (= sprite-desktop--failed-count 0))
            (should-not (seq-some (lambda (m) (string-search "no longer accessible" m))
                                  messages))
            (when-let* ((buf (find-buffer-visiting existing)))
              (kill-buffer buf)))
        (when (file-exists-p existing)
          (delete-file existing))))))

(ert-deftest sprite-desktop/materialize-skips-disappeared-file ()
  "Files removed after staging are dropped quietly without failing."
  (sprite-desktop-test/with-env
    (let* ((missing "/tmp/sprite-desktop-disappeared-file.el")
           (entry (make-sprite-desktop-entry
                   :args (list 208 missing "missing" 'text-mode nil 1 nil nil nil)
                   :file missing
                   :mode 'text-mode
                   :lane 'light
                   :state 'pending))
           (messages nil))
      (push entry (alist-get 'light sprite-desktop--queue))
      (puthash missing entry sprite-desktop--index)
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args)
                   (push (apply #'format fmt args) messages))))
        (should (null (sprite-desktop--materialize entry)))
        (should (eq (sprite-desktop-entry-state entry) 'dropped))
        (should (= sprite-desktop--failed-count 0))
        (should (= sprite-desktop--completed-count 1))
        (should-not (seq-some (lambda (m) (string-search "no longer accessible" m))
                              messages))))))

(ert-deftest sprite-desktop/indicator-string ()
  "Indicator string formats correctly and includes lsp count when bound."
  (sprite-desktop-test/with-env
    (setq sprite-desktop--total-count 10
          sprite-desktop--completed-count 4)
    (let ((e (make-sprite-desktop-entry :lane 'hot :state 'pending)))
      (push e (alist-get 'hot sprite-desktop--queue))
      (should (string-search "⧗ desktop 4/10" (sprite-desktop--indicator-string)))
      ;; When eglox-activate-queue has entries
      (let ((eglox-activate-queue '(1 2 3)))
        (should (string-search "· lsp 3" (sprite-desktop--indicator-string)))))))

(ert-deftest sprite-desktop/queue-menu-and-operations ()
  "Queue menu renders entries and supports bump, drop, and project restore."
  (sprite-desktop-test/with-env
    (let* ((e1 (make-sprite-desktop-entry
                :file "/p1/f1.el" :name "f1.el" :lane 'cold :score 10.0 :est-ms 10 :state 'pending :project "/p1/"))
           (e2 (make-sprite-desktop-entry
                :file "/p2/f2.el" :name "f2.el" :lane 'light :score 20.0 :est-ms 20 :state 'pending :project "/p2/")))
      (push e1 (alist-get 'cold sprite-desktop--queue))
      (push e2 (alist-get 'light sprite-desktop--queue))
      (puthash "/p1/f1.el" e1 sprite-desktop--index)
      (puthash "/p2/f2.el" e2 sprite-desktop--index)
      (let ((buf (get-buffer-create "*sprite-desktop*")))
        (unwind-protect
            (with-current-buffer buf
              (sprite-desktop-queue-mode)
              (sprite-desktop-queue-refresh)
              ;; Buffer should contain both entries
              (should (string-search "f1.el" (buffer-string)))
              (should (string-search "f2.el" (buffer-string)))
              ;; Drop e1
              (goto-char (point-min))
              (search-forward "/p1/f1.el")
              (beginning-of-line)
              (should (eq (tabulated-list-get-id) e1))
              (sprite-desktop-queue-drop)
              (should (eq (sprite-desktop-entry-state e1) 'dropped))
              (should-not (gethash "/p1/f1.el" sprite-desktop--index))
              ;; Restore project for e2
              (goto-char (point-min))
              (search-forward "/p2/f2.el")
              (beginning-of-line)
              (should (eq (tabulated-list-get-id) e2))
              (cl-letf (((symbol-function 'sprite-desktop--materialize)
                         (lambda (entry) (setf (sprite-desktop-entry-state entry) 'done))))
                (sprite-desktop-queue-restore-project)
                (should (eq (sprite-desktop-entry-state e2) 'done))))
          (kill-buffer buf))))))

(provide 'test-sprite-desktop)
;;; test-sprite-desktop.el ends here
