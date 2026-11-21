;;; code-reader-test.el --- ERT tests for Code Reader -*- lexical-binding: t; -*-

;;; Commentary:

;; Run from the package root:
;;   emacs -Q --batch -L doom/code-reader -L tests/elisp \
;;     -l tests/elisp/code-reader-test.el -f ert-run-tests-batch-and-exit
;;
;; The unit and window tests need no engine.  The end-to-end test starts the
;; real engine with tests/fixtures/fake_claude.py and is skipped when either is
;; missing.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'code-reader)

;;; Helpers

(defun code-reader-test--result (id sections &rest extra)
  "Return a protocol `result' event with request ID, SECTIONS and EXTRA plist entries."
  (append (list :type "result"
                :id id
                :task "explain_file"
                :cache_hit :false
                :summary "T\u00f3m t\u1eaft."
                :sections sections
                :dependencies (list "dep-one")
                :data_flow nil
                :notes (list "a note")
                :warnings (list (list :code "context_truncated"
                                      :message "context was cut"
                                      :section_id nil)))
          extra))

(defun code-reader-test--section (id start end title text)
  "Return a protocol section plist."
  (list :id id :source_start start :source_end end :title title :explanation text))

(defun code-reader-test--source-buffer (line-count &optional file)
  "Return a fresh emacs-lisp buffer with LINE-COUNT lines, visiting FILE."
  (let ((buffer (generate-new-buffer " *code-reader-src*")))
    (with-current-buffer buffer
      (emacs-lisp-mode)
      (dotimes (i line-count)
        (insert (format "line %03d\n" (1+ i))))
      (setq buffer-file-name (or file "/nonexistent-project/src/sample.el")))
    buffer))

(defun code-reader-test--line-pos (buffer line)
  "Return the start position of absolute LINE in BUFFER."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (forward-line (1- line))
      (point))))

(defun code-reader-test--heading-pos (view id)
  "Return the explanation-buffer position where section ID starts in VIEW.
`text-property-any' compares with `eq', so the ids are compared with `equal' here."
  (with-current-buffer (code-reader-view-explanation-buffer view)
    (let ((pos (point-min))
          (found nil))
      (while (and (not found) (< pos (point-max)))
        (if (equal (get-text-property pos 'code-reader-section-id) id)
            (setq found pos)
          (setq pos (or (next-single-property-change pos 'code-reader-section-id
                                                     nil (point-max))
                        (point-max)))))
      found)))

(defun code-reader-test--wait (predicate seconds)
  "Run the event loop until PREDICATE returns non-nil or SECONDS pass.  Return its value."
  (let ((deadline (+ (float-time) seconds)))
    (while (and (not (funcall predicate))
                (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (funcall predicate)))

(defconst code-reader-test--window-sections
  (list (code-reader-test--section "w-s1" 1 10 "Intro" "Intro text.")
        (code-reader-test--section "w-s2" 11 30 "Setup" "Setup text.")
        (code-reader-test--section "w-s3" 31 31 "Tiny" "Tiny text.")
        (code-reader-test--section "w-s4" 32 60 "Body" "Body text.")
        (code-reader-test--section "w-s5" 40 45 "Nested" "Nested text.")
        (code-reader-test--section "w-s6" 101 150 "Tail" "Tail text."))
  "Sections used by the window tests.  Section w-s5 is nested inside w-s4.")

(defmacro code-reader-test--with-panes (line-count sections &rest body)
  "Run BODY with a source buffer of LINE-COUNT lines and SECTIONS shown in two panes.
Binds `view', `source', `src-win' and `exp-win'."
  (declare (indent 2))
  `(let* ((source (code-reader-test--source-buffer ,line-count))
          (view (code-reader-session-view-for source))
          (saved-config (current-window-configuration)))
     (unwind-protect
         (progn
           (setf (code-reader-view-pending-id view) "pane-1"
                 (code-reader-view-status view) 'queued)
           (code-reader-session-handle-event
            (code-reader-test--result "pane-1" ,sections))
           (code-reader-ui-open view)
           (let ((src-win (code-reader-ui-source-window view))
                 (exp-win (code-reader-ui-explanation-window view)))
             (ignore src-win exp-win)
             ,@body))
       (set-window-configuration saved-config)
       (code-reader-session-dispose view)
       (kill-buffer source))))

;;; Transport framing and encoding

(ert-deftest code-reader-test-framing-split-chunks ()
  "A JSON line split over several chunks is decoded once it is complete."
  (let* ((pending "")
         (lines nil))
    (dolist (chunk '("{\"type\":\"po" "ng\",\"proto" "col\":1}\n{\"ty"))
      (let ((split (code-reader-transport-decode-chunk pending chunk)))
        (setq lines (append lines (car split))
              pending (cdr split))))
    (should (equal lines '("{\"type\":\"pong\",\"protocol\":1}")))
    (should (equal pending "{\"ty"))
    (let ((rest (code-reader-transport-decode-chunk pending "pe\":\"bye\"}\n")))
      (should (equal (car rest) '("{\"type\":\"bye\"}")))
      (should (equal (cdr rest) "")))))

(ert-deftest code-reader-test-framing-multiple-objects-per-chunk ()
  "A chunk holding several objects yields one line per object and keeps the tail."
  (let* ((chunk "{\"type\":\"progress\",\"id\":\"a\"}\n\n{\"type\":\"cancel_ack\"}\n{\"type\":\"bye\"")
         (split (code-reader-transport-decode-chunk "" chunk)))
    (should (equal (length (car split)) 3))
    (should (equal (cdr split) "{\"type\":\"bye\""))
    (let ((messages (delq nil (mapcar #'code-reader-transport-parse-line (car split)))))
      (should (equal (mapcar (lambda (m) (plist-get m :type)) messages)
                     '("progress" "cancel_ack"))))))

(ert-deftest code-reader-test-parse-line-decodes-json-values ()
  "Parsing maps null to nil, false to :false, arrays to lists and UTF-8 text correctly."
  (let ((message (code-reader-transport-parse-line
                  "{\"type\":\"result\",\"model\":null,\"cache_hit\":false,\"notes\":[\"x\"],\"summary\":\"T\\u00f3m t\\u1eaft\"}")))
    (should (equal (plist-get message :type) "result"))
    (should (null (plist-get message :model)))
    (should (eq (plist-get message :cache_hit) :false))
    (should (equal (plist-get message :notes) '("x")))
    (should (equal (plist-get message :summary) "T\u00f3m t\u1eaft")))
  (should (null (code-reader-transport-parse-line "   ")))
  (should (null (code-reader-transport-parse-line "not json"))))

(ert-deftest code-reader-test-encode-nil-as-null ()
  "Outgoing nil values become JSON null, not an empty object; false and true stay typed."
  (let* ((line (code-reader-transport-encode
                (list :type "explain" :symbol nil :model nil :use_cache :false
                      :target (list :start_line 1 :end_line 2))))
         (parsed (json-parse-string line :object-type 'plist :null-object nil
                                    :false-object :false)))
    (should (string-match-p "\"symbol\":null" line))
    (should (string-match-p "\"use_cache\":false" line))
    (should (null (plist-get parsed :symbol)))
    (should (equal (plist-get (plist-get parsed :target) :end_line) 2))))

;;; Pure section lookup

(ert-deftest code-reader-test-section-at-line-prefers-smallest-span ()
  "Among containing sections the smallest span wins, then the lower start."
  (let ((sections (list (list :id "outer" :start-line 32 :end-line 60)
                        (list :id "inner" :start-line 40 :end-line 45)
                        (list :id "single" :start-line 31 :end-line 31))))
    (should (equal (plist-get (code-reader-highlight-section-at-line sections 42) :id) "inner"))
    (should (equal (plist-get (code-reader-highlight-section-at-line sections 35) :id) "outer"))
    (should (equal (plist-get (code-reader-highlight-section-at-line sections 31) :id) "single"))
    (should (null (code-reader-highlight-section-at-line sections 70)))
    (let ((ties (list (list :id "late" :start-line 5 :end-line 7)
                      (list :id "early" :start-line 3 :end-line 5))))
      (should (equal (plist-get (code-reader-highlight-section-at-line ties 5) :id) "early")))))

(ert-deftest code-reader-test-nearest-section ()
  "Without a containing section, the nearest one is chosen; ties go to the lower start."
  (let ((sections (list (list :id "a" :start-line 32 :end-line 60)
                        (list :id "b" :start-line 101 :end-line 150))))
    (should (equal (plist-get (code-reader-highlight-nearest-section sections 70) :id) "a"))
    (should (equal (plist-get (code-reader-highlight-nearest-section sections 62) :id) "a"))
    (should (equal (plist-get (code-reader-highlight-nearest-section sections 95) :id) "b"))
    (should (null (code-reader-highlight-nearest-section nil 5))))
  (let ((tie (list (list :id "first" :start-line 10 :end-line 12)
                   (list :id "second" :start-line 16 :end-line 18))))
    (should (equal (plist-get (code-reader-highlight-nearest-section tie 14) :id) "first"))))

;;; Section mapping with markers

(ert-deftest code-reader-test-section-markers-follow-edits-above ()
  "Sections keep their text after an insertion above them, through markers."
  (let* ((source (code-reader-test--source-buffer 40))
         (view (code-reader-session-view-for source)))
    (unwind-protect
        (progn
          (setf (code-reader-view-pending-id view) "map-1")
          (code-reader-session-handle-event
           (code-reader-test--result
            "map-1" (list (code-reader-test--section "map-1-s1" 10 12 "Mid" "Mid text."))))
          (let ((before (car (code-reader-session-live-sections view))))
            (should (equal (plist-get before :start-line) 10))
            (should (equal (plist-get before :end-line) 12))
            (with-current-buffer source
              (save-excursion
                (goto-char (point-min))
                (insert "new first line\nnew second line\n")))
            (let ((after (car (code-reader-session-live-sections view))))
              (should (equal (plist-get after :start-line) 12))
              (should (equal (plist-get after :end-line) 14))
              (with-current-buffer source
                (goto-char (code-reader-test--line-pos source 12))
                (should (equal (buffer-substring-no-properties
                                (line-beginning-position)
                                (line-end-position))
                               "line 010")))
              (should (equal (plist-get after :id) "map-1-s1")))))
      (code-reader-session-dispose view)
      (kill-buffer source))))

(ert-deftest code-reader-test-result-drops-invalid-sections ()
  "Sections whose range is not inside the file are not mapped to markers."
  (let* ((source (code-reader-test--source-buffer 5))
         (view (code-reader-session-view-for source)))
    (unwind-protect
        (progn
          (setf (code-reader-view-pending-id view) "inv-1")
          (code-reader-session-handle-event
           (code-reader-test--result
            "inv-1"
            (list (code-reader-test--section "inv-1-s1" 2 3 "ok" "ok")
                  (code-reader-test--section "inv-1-s2" 4 2 "reversed" "bad"))))
          (should (= (length (code-reader-view-sections view)) 1))
          (should (equal (plist-get (car (code-reader-view-sections view)) :id) "inv-1-s1")))
      (code-reader-session-dispose view)
      (kill-buffer source))))

;;; Stale detection

(ert-deftest code-reader-test-stale-after-edit-and-not-after-identical-text ()
  "An edit marks a ready view stale; an edit that restores the text does not."
  (let* ((source (code-reader-test--source-buffer 8))
         (view (code-reader-session-view-for source)))
    (unwind-protect
        (progn
          (setf (code-reader-view-status view) 'ready
                (code-reader-view-snapshot-hash view)
                (secure-hash 'sha256 (code-reader-session--buffer-text source))
                (code-reader-view-snapshot-tick view)
                (with-current-buffer source (buffer-chars-modified-tick)))
          ;; No change yet: nothing happens.
          (code-reader-session-check-stale view)
          (should (eq (code-reader-view-status view) 'ready))
          ;; Insert and delete the same text: the tick moves, the text does not.
          (with-current-buffer source
            (goto-char (point-min))
            (insert "x")
            (delete-char -1))
          (code-reader-session-check-stale view)
          (should (eq (code-reader-view-status view) 'ready))
          ;; A real change makes the view stale.
          (with-current-buffer source
            (goto-char (point-min))
            (insert "changed\n"))
          (code-reader-session-check-stale view)
          (should (eq (code-reader-view-status view) 'stale)))
      (code-reader-session-dispose view)
      (kill-buffer source))))

;;; Request building

(ert-deftest code-reader-test-request-widened-absolute-lines ()
  "The request carries the whole widened buffer and absolute line numbers."
  (let* ((dir (make-temp-file "code-reader-req-" t))
         (file (expand-file-name "lisp/foo.el" dir))
         (buffer nil))
    (unwind-protect
        (progn
          (make-directory (expand-file-name ".git" dir) t)
          (make-directory (file-name-directory file) t)
          (with-temp-file file
            (dotimes (i 10) (insert (format "(defun f%d () %d)\n" i i))))
          (setq buffer (find-file-noselect file))
          (with-current-buffer buffer
            (narrow-to-region (code-reader-test--line-pos buffer 4)
                              (code-reader-test--line-pos buffer 7))
            (goto-char (point-min))
            (let* ((request (code-reader-session-build-request
                             :id "req-1" :task "explain_block"
                             :start-line 4 :end-line 6 :point-pos (point)
                             :use-cache nil))
                   (content (plist-get request :content)))
              (should (equal (plist-get request :type) "explain"))
              (should (equal (plist-get request :id) "req-1"))
              (should (equal (plist-get request :task) "explain_block"))
              (should (string-match-p "f0 " content))
              (should (string-match-p "f9 " content))
              (should (equal (plist-get request :target) '(:start_line 4 :end_line 6)))
              (should (= (plist-get request :point_line) 4))
              (should (equal (plist-get request :language) "emacs-lisp-mode"))
              (should (equal (file-truename (plist-get request :file))
                             (file-truename file)))
              (should (equal (file-truename (plist-get request :project_root))
                             (file-truename dir)))
              (should (eq (plist-get request :use_cache) :false))
              (should (equal (plist-get request :explain_language) code-reader-explain-language))
              (should (equal (plist-get request :timeout) code-reader-timeout))
              (should (eq (plist-get request :model) nil))
              (let ((line (code-reader-transport-encode request)))
                (should (string-match-p "\"model\":null" line))
                (should (string-match-p "\"use_cache\":false" line))))))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer (widen))
        (kill-buffer buffer))
      (delete-directory dir t))))

(ert-deftest code-reader-test-project-root-prefers-git-marker ()
  "Without projectile, the project root is the nearest directory holding .git."
  (let* ((dir (make-temp-file "code-reader-root-" t))
         (sub (expand-file-name "a/b" dir)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name ".git" dir) t)
          (make-directory sub t)
          (let ((root (code-reader-session-project-root (expand-file-name "f.el" sub))))
            (should (equal (file-truename root) (file-truename (file-name-as-directory dir))))))
      (delete-directory dir t))))

;;; Explain targets

(ert-deftest code-reader-test-defun-lines-on-opening-and-body-lines ()
  "The function containing point gives its first and last lines."
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert "(defun a ()\n  1)\n\n(defun b ()\n  (+ 1\n     2))\n\n(message \"x\")\n")
    (goto-char (point-min))
    (search-forward "(defun b")
    (beginning-of-line)
    (should (equal (code-reader-commands--defun-lines) '(4 . 6)))
    (forward-line 1)
    (should (equal (code-reader-commands--defun-lines) '(4 . 6)))
    (goto-char (point-min))
    (should (equal (code-reader-commands--defun-lines) '(1 . 2)))
    (goto-char (point-min))
    (forward-line 2)
    (should (null (code-reader-commands--defun-lines)))
    (goto-char (point-min))
    (forward-line 6)
    (should (null (code-reader-commands--defun-lines)))))

(ert-deftest code-reader-test-explain-block-excludes-column-zero-end ()
  "A region that ends at column 0 leaves that last line out of the target."
  (let ((captured nil)
        (transient-mark-mode t)
        (source (code-reader-test--source-buffer 10)))
    (unwind-protect
        (with-current-buffer source
          (cl-letf (((symbol-function 'code-reader-commands--explain)
                     (lambda (task start end _note) (setq captured (list task start end)))))
            (goto-char (code-reader-test--line-pos source 2))
            (set-mark (point))
            (activate-mark)
            (goto-char (code-reader-test--line-pos source 5))
            (code-reader-explain-block)
            (should (equal captured '("explain_block" 2 4)))
            (goto-char (code-reader-test--line-pos source 5))
            (end-of-line)
            (set-mark (code-reader-test--line-pos source 2))
            (activate-mark)
            (code-reader-explain-block)
            (should (equal (cdr captured) '(2 5)))))
      (kill-buffer source))))

(ert-deftest code-reader-test-explain-block-needs-a-region ()
  "Explaining a block without an active region is a user error."
  (let ((transient-mark-mode t)
        (source (code-reader-test--source-buffer 3)))
    (unwind-protect
        (with-current-buffer source
          (deactivate-mark)
          (should-error (code-reader-explain-block) :type 'user-error))
      (kill-buffer source))))

;;; Rendering

(ert-deftest code-reader-test-render-canned-result ()
  "A canned result renders its summary, section headings with properties and lists."
  (let* ((source (code-reader-test--source-buffer 12))
         (view (code-reader-session-view-for source)))
    (unwind-protect
        (progn
          (setf (code-reader-view-pending-id view) "rend-1"
                (code-reader-view-status view) 'queued
                (code-reader-view-task view) "explain_block")
          (code-reader-session-handle-event
           (code-reader-test--result
            "rend-1"
            (list (code-reader-test--section "rend-1-s1" 3 5 "Gán giá trị" "First explanation.")
                  (code-reader-test--section "rend-1-s2" 9 9 "Second" "Second explanation."))))
          (should (eq (code-reader-view-status view) 'ready))
          (let ((buffer (code-reader-view-explanation-buffer view)))
            (with-current-buffer buffer
              (should (derived-mode-p 'code-reader-explanation-mode))
              (should (string-match-p "T\u00f3m t\u1eaft" (buffer-string)))
              (should (string-match-p "Lines 3–5 · Gán giá trị" (buffer-string)))
              (should (string-match-p "Lines 9–9 · Second" (buffer-string)))
              (should (string-match-p "First explanation\\." (buffer-string)))
              (should (string-match-p "Dependencies" (buffer-string)))
              (should (string-match-p "\\[context_truncated\\] context was cut" (buffer-string)))
              (let ((heading (code-reader-test--heading-pos view "rend-1-s1")))
                (should heading)
                (should (equal (get-text-property heading 'code-reader-source-start) 3))
                (should (equal (get-text-property heading 'code-reader-source-end) 5)))
              (should (string-match-p "ready" header-line-format))
              (should (string-match-p "explain_block\\|block" header-line-format)))))
      (code-reader-session-dispose view)
      (kill-buffer source))))

(ert-deftest code-reader-test-active-highlight-covers-one-section ()
  "Highlighting one section does not spill into the sections rendered after it."
  (let* ((source (code-reader-test--source-buffer 12))
         (view (code-reader-session-view-for source)))
    (unwind-protect
        (progn
          (setf (code-reader-view-pending-id view) "hl-1"
                (code-reader-view-status view) 'queued
                (code-reader-view-task view) "explain_file")
          (code-reader-session-handle-event
           (code-reader-test--result
            "hl-1"
            (list (code-reader-test--section "hl-1-s1" 1 3 "First" "First explanation.")
                  (code-reader-test--section "hl-1-s2" 5 8 "Second" "Second explanation.")
                  (code-reader-test--section "hl-1-s3" 10 11 "Third" "Third explanation."))))
          (let* ((sections (code-reader-view-sections view))
                 (first (nth 0 sections))
                 (second (nth 1 sections))
                 (buffer (code-reader-view-explanation-buffer view)))
            (should (<= (marker-position (plist-get first :exp-end))
                        (marker-position (plist-get second :exp-start))))
            (code-reader-sync--highlight-active view first)
            (with-current-buffer buffer
              (should (overlayp code-reader-highlight--active-overlay))
              (should (<= (overlay-end code-reader-highlight--active-overlay)
                          (marker-position (plist-get second :exp-start)))))))
      (code-reader-session-dispose view)
      (kill-buffer source))))

(ert-deftest code-reader-test-key-guide-shows-on-entering-explanation ()
  "Moving from the source pane into the explanation pane shows the key guide below it."
  (code-reader-test--with-panes 200 code-reader-test--window-sections
    (unwind-protect
        (progn
          (select-window src-win)
          (setq code-reader-guide--last-window src-win)
          (select-window exp-win)
          (code-reader-guide--post-command)
          (should (window-live-p code-reader-guide--window))
          (should (= (nth 1 (window-edges code-reader-guide--window))
                     (nth 3 (window-edges exp-win))))
          (should (string-match-p "jump to source"
                                  (with-current-buffer (window-buffer code-reader-guide--window)
                                    (buffer-string)))))
      (code-reader-guide-hide))))

(ert-deftest code-reader-test-key-guide-hides-while-moving-inside-explanation ()
  "Moving the cursor inside the explanation pane hides the guide; re-entering shows it again."
  (code-reader-test--with-panes 200 code-reader-test--window-sections
    (unwind-protect
        (progn
          (select-window src-win)
          (setq code-reader-guide--last-window src-win)
          (select-window exp-win)
          (code-reader-guide--post-command)
          (should (window-live-p code-reader-guide--window))
          ;; A command that leaves the cursor where it is keeps the guide.
          (code-reader-guide--post-command)
          (should (window-live-p code-reader-guide--window))
          ;; Moving the cursor inside the explanation pane hides it.
          (with-current-buffer (window-buffer exp-win) (goto-char (point-min)))
          (code-reader-guide--post-command)
          (should-not (window-live-p code-reader-guide--window))
          ;; Back to the source, then into the explanation again.
          (select-window src-win)
          (code-reader-guide--post-command)
          (select-window exp-win)
          (code-reader-guide--post-command)
          (should (window-live-p code-reader-guide--window))
          ;; Leaving for the source hides it.
          (select-window src-win)
          (code-reader-guide--post-command)
          (should-not (window-live-p code-reader-guide--window)))
      (code-reader-guide-hide))))

(ert-deftest code-reader-test-layout-installs-the-key-guide ()
  "Opening the layout installs the post-command hooks in both panes."
  (code-reader-test--with-panes 200 code-reader-test--window-sections
    (unwind-protect
        (progn
          (code-reader-commands--show view)
          (dolist (buffer (list source (code-reader-view-explanation-buffer view)))
            (with-current-buffer buffer
              (should (memq #'code-reader-guide--post-command post-command-hook))
              (should (memq #'code-reader-sync--post-command post-command-hook)))))
      ;; Opening the layout installs the global scroll hook.  Remove it so that
      ;; the tests that run after this one do not get scroll events.
      (remove-hook 'window-scroll-functions #'code-reader-sync--on-window-scroll))))

(ert-deftest code-reader-test-cursor-sync-runs-when-the-source-hook-is-shadowed ()
  "Cursor sync still runs when the source buffer's local `post-command-hook' omits the global value."
  (code-reader-test--with-panes 200 code-reader-test--window-sections
    (with-current-buffer source
      (setq-local post-command-hook (list #'ignore)))
    (code-reader-commands--install-pane-hooks view)
    (unwind-protect
        (progn
          (with-current-buffer source
            (goto-char (code-reader-test--line-pos source 42))
            (run-hooks 'post-command-hook))
          (should (timerp (code-reader-view-point-timer view)))
          (should (= (code-reader-view-last-point view)
                     (with-current-buffer source (point)))))
      (when (timerp (code-reader-view-point-timer view))
        (cancel-timer (code-reader-view-point-timer view))))))

(ert-deftest code-reader-test-key-guide-table-lists-the-keys ()
  "The key guide is a table with a Go to / Actions header and the pane's keys."
  (let ((text (mapconcat #'substring-no-properties (code-reader-guide--lines) "\n")))
    (should (string-match-p "Go to.*Actions" text))
    (should (string-match-p "RET: jump to source" text))
    (should (string-match-p "g: refresh" text))
    (should (string-match-p "c: cancel" text))
    (should (string-match-p "t / q: hide pane, close" text))
    (should (= (length (code-reader-guide--lines)) (+ 2 (length code-reader-guide-rows))))))

(ert-deftest code-reader-test-render-error-shows-code-and-message ()
  "An error event renders the error code, its message and the source lines."
  (let* ((source (code-reader-test--source-buffer 6))
         (view (code-reader-session-view-for source)))
    (unwind-protect
        (progn
          (setf (code-reader-view-pending-id view) "err-1"
                (code-reader-view-status view) 'queued
                (code-reader-view-target view)
                (code-reader-session--make-target source 2 2 (code-reader-test--line-pos source 2)))
          (code-reader-session-handle-event
           (list :type "error" :id "err-1" :code "claude_timeout"
                 :message "Claude did not finish within 180s" :retryable t))
          (should (eq (code-reader-view-status view) 'error))
          (with-current-buffer (code-reader-view-explanation-buffer view)
            (should (string-match-p "Error: claude_timeout" (buffer-string)))
            (should (string-match-p "did not finish within 180s" (buffer-string)))
            (should (string-match-p "line 002" (buffer-string)))
            (should (string-match-p "error: claude_timeout" header-line-format))))
      (code-reader-session-dispose view)
      (kill-buffer source))))

(ert-deftest code-reader-test-stale-header-and-queued-header ()
  "The header names the status, including the stale notice with the refresh hint."
  (let* ((source (code-reader-test--source-buffer 4))
         (view (code-reader-session-view-for source)))
    (unwind-protect
        (progn
          (setf (code-reader-view-status view) 'queued
                (code-reader-view-task view) "explain_file"
                (code-reader-view-claude-session view) "resumed")
          (should (string-match-p "queued" (code-reader-ui-header-string view)))
          (should (string-match-p "Claude: resumed" (code-reader-ui-header-string view)))
          (setf (code-reader-view-status view) 'stale)
          (should (string-match-p "stale — press g to refresh"
                                  (code-reader-ui-header-string view))))
      (code-reader-session-dispose view)
      (kill-buffer source))))

(ert-deftest code-reader-test-stale-event-ignored-without-matching-id ()
  "A result whose id no longer matches the pending request does not overwrite the view."
  (let* ((source (code-reader-test--source-buffer 4))
         (view (code-reader-session-view-for source)))
    (unwind-protect
        (progn
          (setf (code-reader-view-pending-id view) "current"
                (code-reader-view-status view) 'queued)
          (code-reader-session-handle-event (code-reader-test--result "older" nil))
          (should (eq (code-reader-view-status view) 'queued))
          (should (equal (code-reader-view-pending-id view) "current"))
          (should (null (code-reader-view-last-result view))))
      (code-reader-session-dispose view)
      (kill-buffer source))))

;;; Window layout

(ert-deftest code-reader-test-layout-open-and-close-restores-windows ()
  "Opening makes two panes; closing restores the original window configuration."
  (let* ((source (code-reader-test--source-buffer 5))
         (view (code-reader-session-view-for source)))
    (unwind-protect
        (progn
          (delete-other-windows)
          (set-window-buffer (selected-window) source)
          (let ((before (current-window-configuration)))
            (code-reader-ui-open view)
            (should (= (length (window-list)) 2))
            (should (code-reader-ui-explanation-window view))
            (should (eq (window-buffer (code-reader-ui-source-window view)) source))
            (code-reader-ui-hide-panel view)
            (should (= (length (window-list)) 1))
            (code-reader-ui-open view)
            (should (= (length (window-list)) 2))
            (code-reader-ui-close view)
            (should (window-configuration-equal-p before (current-window-configuration)))))
      (code-reader-session-dispose view)
      (kill-buffer source))))

;;; Pane synchronisation (window level, no timers)

(ert-deftest code-reader-test-sync-source-to-explanation ()
  "Scrolling the source pane puts the section at its middle at the top of the explanation."
  (code-reader-test--with-panes 200 code-reader-test--window-sections
    (set-window-start src-win (code-reader-test--line-pos source 100))
    (code-reader-sync-source-scrolled view)
    (let* ((middle (+ 100 (/ (window-body-height src-win) 2)))
           (expected (code-reader-highlight-nearest-section
                      (code-reader-session-live-sections view) middle)))
      (should (= (window-start exp-win)
                 (code-reader-test--heading-pos view (plist-get expected :id)))))))

(ert-deftest code-reader-test-sync-source-does-not-move-source-point ()
  "Source-driven sync leaves the source point where it was."
  (code-reader-test--with-panes 200 code-reader-test--window-sections
    (goto-char (code-reader-test--line-pos source 150))
    (let ((point-before (point)))
      (set-window-start src-win (code-reader-test--line-pos source 20))
      (code-reader-sync-source-scrolled view)
      (should (= (point) point-before)))))

(ert-deftest code-reader-test-sync-explanation-to-source ()
  "Scrolling the explanation pane scrolls the source to the section's start, without moving point."
  (code-reader-test--with-panes 200 code-reader-test--window-sections
    (let* ((section (code-reader-session-section-by-id view "w-s2"))
           (heading (code-reader-test--heading-pos view "w-s2")))
      (set-window-start exp-win heading)
      (goto-char (code-reader-test--line-pos source 180))
      (let ((point-before (point)))
        (code-reader-sync-explanation-scrolled view)
        (should (= (point) point-before))
        (should (= (window-start src-win)
                   (code-reader-test--line-pos source (plist-get section :start-line))))
        (should (equal (code-reader-view-sync-target view) "w-s2"))))))

(ert-deftest code-reader-test-sync-skips-unchanged-target ()
  "A source sync that lands in the same section does not move the explanation again."
  (code-reader-test--with-panes 200 code-reader-test--window-sections
    (set-window-start src-win (code-reader-test--line-pos source 110))
    (code-reader-sync-source-scrolled view)
    (should (= (window-start exp-win) (code-reader-test--heading-pos view "w-s6")))
    ;; The reader scrolls the explanation by hand to section w-s1.
    (set-window-start exp-win (code-reader-test--heading-pos view "w-s1"))
    ;; The source moves a little, but its middle is still inside w-s6.
    (set-window-start src-win (code-reader-test--line-pos source 111))
    (code-reader-sync-source-scrolled view)
    (should (= (window-start exp-win) (code-reader-test--heading-pos view "w-s1")))))

(ert-deftest code-reader-test-recursion-guard-blocks-scroll-events ()
  "Scroll events raised while code moves a window are ignored (no reentry).
Scroll events are debounced: a genuine scroll schedules one idle timer."
  (code-reader-test--with-panes 200 code-reader-test--window-sections
    (set-window-start src-win (code-reader-test--line-pos source 100))
    (code-reader-sync-source-scrolled view)
    (should-not code-reader-sync--syncing)
    (should-not (code-reader-view-scroll-timer view))
    ;; While the guard is bound, a scroll event does not schedule anything.
    (let ((code-reader-sync--syncing t))
      (code-reader-sync--on-window-scroll exp-win 1))
    (should-not (code-reader-view-scroll-timer view))
    ;; A genuine scroll schedules exactly one debounced sync.
    (code-reader-sync--on-window-scroll exp-win 1)
    (let ((timer (code-reader-view-scroll-timer view)))
      (should (timerp timer))
      (code-reader-sync--on-window-scroll exp-win 1)
      (should (eq timer (code-reader-view-scroll-timer view))))
    (cancel-timer (code-reader-view-scroll-timer view))
    (setf (code-reader-view-scroll-timer view) nil)))

(ert-deftest code-reader-test-jump-moves-source-point-and-highlights ()
  "Jumping to a section moves the source point to its first line and highlights it."
  (code-reader-test--with-panes 200 code-reader-test--window-sections
    (code-reader-sync-jump view "w-s2")
    (should (= (with-current-buffer source (line-number-at-pos (point) t)) 11))
    (should (= (window-point src-win) (with-current-buffer source (point))))
    (should (cl-some (lambda (ov) (overlay-get ov 'face)) (with-current-buffer source
                                                           (overlays-in (point-min) (point-max)))))
    (should (equal (code-reader-view-sync-target view) "w-s2"))))

(ert-deftest code-reader-test-cursor-sync-highlights-section-at-point ()
  "Moving point in the source highlights the containing section, without scrolling."
  (code-reader-test--with-panes 200 code-reader-test--window-sections
    (let ((window-start-before (window-start exp-win)))
      (with-current-buffer source
        (goto-char (code-reader-test--line-pos source 42)))
      (code-reader-sync--run-point view)
      (should (equal (code-reader-view-active-section-id view) "w-s5"))
      (should (= (window-start exp-win) window-start-before)))))

(ert-deftest code-reader-test-explanation-scroll-keeps-cursor-highlight ()
  "Scrolling the explanation moves the source, but the highlight stays on the cursor's section."
  (code-reader-test--with-panes 200 code-reader-test--window-sections
    (with-current-buffer source (goto-char (code-reader-test--line-pos source 50)))
    (code-reader-sync--run-point view)
    (should (equal (code-reader-view-active-section-id view) "w-s4"))
    (set-window-start exp-win (code-reader-test--heading-pos view "w-s2"))
    (code-reader-sync-explanation-scrolled view)
    (should (equal (code-reader-view-sync-target view) "w-s2"))
    (should (= (window-start src-win)
               (code-reader-test--line-pos source 11)))
    (should (= (with-current-buffer source (point))
               (code-reader-test--line-pos source 50)))
    (should (equal (code-reader-view-active-section-id view) "w-s4"))))

;;; End-to-end (real engine and fake claude)

(ert-deftest code-reader-test-e2e-explain-file-through-engine ()
  "A real engine answers a whole-file explain request with sections covering the file."
  :tags '(e2e)
  (let* ((root code-reader-package-root)
         (engine (expand-file-name "engine/__main__.py" root))
         (fixture (expand-file-name "tests/fixtures/fake_claude.py" root)))
    (skip-unless (file-exists-p engine))
    (skip-unless (file-executable-p fixture))
    (skip-unless (executable-find "python3"))
    (let* ((tmp (file-name-as-directory (make-temp-file "cr-e2e-" t)))
           (socket (expand-file-name "e.sock" tmp))
           (project (expand-file-name "project/" tmp))
           (file (expand-file-name "lisp/sample.el" project))
           (buffer nil)
           (view nil)
           (code-reader-socket-file socket)
           (code-reader-state-directory (expand-file-name "state/" tmp))
           (code-reader-claude-command fixture))
      (skip-unless (< (string-bytes socket) 100))
      (unwind-protect
          (progn
            (make-directory (expand-file-name ".git" project) t)
            (make-directory (file-name-directory file) t)
            (with-temp-file file
              (insert "(defun sample-double (x)\n  \"Double X.\"\n  (* x 2))\n"))
            (setq buffer (find-file-noselect file))
            (setq view (code-reader-session-view-for buffer))
            (with-current-buffer buffer
              (let ((lines (code-reader-session-whole-file-lines buffer)))
                (code-reader-session-explain view "explain_file" (car lines) (cdr lines)
                                             (code-reader-test--line-pos buffer 3))))
            (should (code-reader-test--wait
                     (lambda () (memq (code-reader-view-status view) '(ready cached error)))
                     120))
            (should (eq (code-reader-view-status view) 'ready))
            (should (code-reader-view-sections view))
            (should (plist-get (code-reader-view-last-result view) :summary))
            ;; The fake engine answers with the section that covers the target: the whole
            ;; file, which is four lines here because the text ends with a newline.
            (let ((section (car (code-reader-view-sections view))))
              (should (equal (plist-get section :start-line) 1))
              (should (equal (plist-get section :end-line) 4))))
        (when view
          (code-reader-session-dispose view))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer (set-buffer-modified-p nil))
          (kill-buffer buffer))
        (when (code-reader-transport-connected-p)
          (code-reader-transport-shutdown)
          (code-reader-test--wait (lambda () (not (code-reader-transport-connected-p))) 5))
        (when (process-live-p code-reader-transport--engine)
          (delete-process code-reader-transport--engine))
        (setq code-reader-transport--engine nil)
        (when (file-directory-p tmp)
          (delete-directory tmp t))))))

(ert-deftest code-reader-test-claude-label-comes-from-the-engine ()
  "The new/resumed label follows the engine's session_resumed flag, not history."
  (should (equal (code-reader-session--claude-label
                  '(:cache_hit t :session_resumed :null)) "cached"))
  (should (equal (code-reader-session--claude-label
                  '(:cache_hit :false :session_resumed t :session_id "s")) "resumed"))
  (should (equal (code-reader-session--claude-label
                  '(:cache_hit :false :session_resumed :false :session_id "s")) "new"))
  (should (equal (code-reader-session--claude-label '(:cache_hit :false)) "unknown")))

(ert-deftest code-reader-test-whole-file-lines-ignore-narrowing ()
  "The whole-file range covers every line, even when the buffer is narrowed."
  (with-temp-buffer
    (insert "a\nb\nc\n")
    (should (equal (code-reader-session-whole-file-lines (current-buffer)) '(1 . 4)))
    (narrow-to-region 1 2)
    (should (equal (code-reader-session-whole-file-lines (current-buffer)) '(1 . 4)))))

(ert-deftest code-reader-test-explain-file-header-label ()
  "The header calls a whole-file explanation a file explanation."
  (should (equal (code-reader-ui--task-label "explain_file") "file"))
  (should (equal (code-reader-ui--task-label "explain_block") "block"))
  (should (equal (code-reader-ui--task-label "explain_function") "function")))

(provide 'code-reader-test)
;;; code-reader-test.el ends here
