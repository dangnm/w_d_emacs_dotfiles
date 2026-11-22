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

(defconst code-reader-test--key (make-string 64 ?a)
  "A well-formed explanation key, as the engine sends it.")

(defun code-reader-test--result (id sections &rest extra)
  "Return a protocol `result' event with request ID and SECTIONS.
EXTRA is a plist that overrides the defaults.  The document is built from
SECTIONS, with the summary and lists the defaults name, as the engine would."
  (append extra
          (list :type "result"
                :id id
                :task "explain_file"
                :cache_hit :false
                :explanation_key code-reader-test--key
                :summary "T\u00f3m t\u1eaft."
                :sections sections
                :document (code-reader-test--document sections)
                :dependencies (list "dep-one")
                :data_flow nil
                :notes (list "a note")
                :warnings (list (list :code "context_truncated"
                                      :message "context was cut"
                                      :section_id nil)))))

(defun code-reader-test--section (id start end title text)
  "Return a protocol section plist."
  (list :id id :source_start start :source_end end :title title :explanation text))

(defun code-reader-test--body (text)
  "Return TEXT indented the way the engine indents the body of a heading."
  (mapconcat (lambda (line) (if (string-empty-p line) "" (concat "  " line)))
             (split-string text "\n") "\n"))

(defun code-reader-test--section-org (section)
  "Return the Org heading, drawer, text and questions of protocol SECTION."
  (let* ((start (plist-get section :source_start))
         (end (plist-get section :source_end))
         (title (plist-get section :title))
         (org (format "* Lines %d–%d%s\n  :PROPERTIES:\n  :KIND: section\n  :SECTION_ID: %s\n  :LINES: %d-%d\n  :END:\n%s\n"
                      start end
                      (if (and (stringp title) (not (string-empty-p title)))
                          (format " · %s" title)
                        "")
                      (plist-get section :id) start end
                      (code-reader-test--body (plist-get section :explanation)))))
    ;; A detail explanation is a subsection, written before the questions.  Each item is
    ;; (LINE EXPLANATION), as the engine writes it: the number, then the explanation.
    (let ((detail (plist-get section :detail)))
      (when detail
        (setq org (concat org "** Detail explanation\n  :PROPERTIES:\n  :KIND: detail\n  :END:\n"
                          (mapconcat (lambda (item)
                                       (format "  - %d\n    %s\n" (nth 0 item) (nth 1 item)))
                                     detail "")
                          "\n"))))
    (dolist (followup (plist-get section :followups))
      (setq org (concat org
                        (format "** Question: %s\n  :PROPERTIES:\n  :KIND: question\n  :CREATED: %s\n  :END:\n%s\n"
                                (plist-get followup :question)
                                (or (plist-get followup :created_at) "2026-11-22T10:00:00")
                                (code-reader-test--body (plist-get followup :answer))))))
    org))

(defun code-reader-test--document (sections)
  "Return the Org text the engine would send for SECTIONS and the default lists."
  (concat "#+TITLE: sample.el\n#+STARTUP: overview\n#+OPTIONS: ^:nil\n\n"
          "* Summary\n  :PROPERTIES:\n  :KIND: summary\n  :END:\n  T\u00f3m t\u1eaft.\n\n"
          (mapconcat #'code-reader-test--section-org sections "")
          "* Dependencies\n  :PROPERTIES:\n  :KIND: dependencies\n  :END:\n  - dep-one\n\n"
          "* Notes\n  :PROPERTIES:\n  :KIND: notes\n  :END:\n  - a note\n\n"
          "* Warnings\n  :PROPERTIES:\n  :KIND: warnings\n  :END:\n  - [context_truncated] context was cut\n\n"))

(defun code-reader-test--with-followup (sections id question answer)
  "Return SECTIONS with QUESTION and ANSWER nested under the section with ID."
  (mapcar (lambda (section)
            (if (equal (plist-get section :id) id)
                (append section (list :followups (list (list :question question :answer answer
                                                             :created_at "2026-11-22T10:00:00"))))
              section))
          sections))

(defun code-reader-test--replace-explanation (sections id text)
  "Return SECTIONS with the explanation of the section ID replaced by TEXT."
  (mapcar (lambda (section)
            (if (equal (plist-get section :id) id)
                (let ((copy (copy-sequence section)))
                  (plist-put copy :explanation text)
                  copy)
              section))
          sections))

(defun code-reader-test--text-pos (string)
  "Return the position where STRING starts in the current buffer, or nil."
  (save-excursion
    (goto-char (point-min))
    (when (search-forward string nil t)
      (match-beginning 0))))

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

(ert-deftest code-reader-test-edits-do-not-expire-the-explanation ()
  "An edit leaves a ready explanation in place, with no stale notice, until it is refreshed."
  (let* ((source (code-reader-test--source-buffer 8))
         (view (code-reader-session-view-for source)))
    (unwind-protect
        (progn
          (setf (code-reader-view-status view) 'ready)
          (with-current-buffer source
            (goto-char (point-min))
            (insert "changed\n"))
          (should (eq (code-reader-view-status view) 'ready))
          (should-not (string-match-p "stale" (code-reader-ui-header-string view))))
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
                (goto-char heading)
                (should (looking-at "\\* Lines 3–5 · Gán giá trị"))
                (should (markerp (plist-get (car (code-reader-view-sections view)) :exp-start))))
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
              (should code-reader-highlight--active-marks)
              (should (cl-every (lambda (ov)
                                  (< (overlay-start ov) (marker-position (plist-get second :exp-start))))
                                code-reader-highlight--active-marks)))))
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
          (should code-reader-guide--shown)
          (should (eq (window-buffer (code-reader-chat-panel-window))
                      (get-buffer code-reader-guide-buffer-name)))
          (should (= (nth 1 (window-edges (code-reader-chat-panel-window)))
                     (nth 3 (window-edges exp-win))))
          (should (string-match-p "jump to the source"
                                  (with-current-buffer (window-buffer (code-reader-chat-panel-window))
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
          (should code-reader-guide--shown)
          ;; A command that leaves the cursor where it is keeps the guide.
          (code-reader-guide--post-command)
          (should code-reader-guide--shown)
          ;; Moving the cursor inside the explanation pane hides it.
          (with-current-buffer (window-buffer exp-win) (goto-char (point-min)))
          (code-reader-guide--post-command)
          (should-not code-reader-guide--shown)
          ;; Back to the source, then into the explanation again.
          (select-window src-win)
          (code-reader-guide--post-command)
          (select-window exp-win)
          (code-reader-guide--post-command)
          (should code-reader-guide--shown)
          ;; Leaving for the source hides it.
          (select-window src-win)
          (code-reader-guide--post-command)
          (should-not code-reader-guide--shown))
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
    (should (string-match-p "RET: jump to the source" text))
    (should (string-match-p "g: refresh the explanation" text))
    (should (string-match-p "c: cancel the running request" text))
    (should (string-match-p "r: refresh this section" text))
    (should (string-match-p "t / q: toggle the pane / close the reader" text))
    (should (string-match-p "p: copy the cache file path" text))
    (should (string-match-p "d: delete the question at point" text))
    (should (string-match-p "s: explain this section in detail" text))
    (should (= (length (code-reader-guide--lines)) (+ 2 (length code-reader-guide-rows))))
    ;; The whole table fits in the bottom panel.
    (should (<= (length (code-reader-guide--lines)) code-reader-chat-lines))))

(ert-deftest code-reader-test-copy-cache-path-shows-and-copies-the-path ()
  "The p key shows the explanation's cache file, and copies its path to the kill ring and clipboard."
  (code-reader-test--with-panes 200 code-reader-test--window-sections
    (let ((copied nil)
          (path "/tmp/cache/dotfiles-3f9a2c/lisp/sample.el/whole-file-English-abcd1234.org"))
      (setf (code-reader-view-cache-path view) path)
      (cl-letf (((symbol-function 'code-reader-commands--copy-to-clipboard)
                 (lambda (text) (setq copied text))))
        (with-current-buffer (code-reader-view-explanation-buffer view)
          (code-reader-copy-cache-path)))
      (should (equal (car kill-ring) path))
      (should (equal copied path)))
    (setf (code-reader-view-cache-path view) nil)
    (with-current-buffer (code-reader-view-explanation-buffer view)
      (should-error (code-reader-copy-cache-path) :type 'user-error))))

(ert-deftest code-reader-test-chat-box-sits-under-the-explanation ()
  "The bottom panel, which holds the question box, sits directly below the explanation when shown."
  (code-reader-test--with-panes 200 code-reader-test--window-sections
    (should-not (code-reader-chat--window view))
    (code-reader-chat-show view exp-win)
    (let ((panel (code-reader-chat--window view)))
      (should (window-live-p panel))
      (should (= (nth 1 (window-edges panel)) (nth 3 (window-edges exp-win))))
      (should (eq (window-buffer panel) (code-reader-chat--buffer-of view)))
      ;; The key table must fit the panel, or it would be cut off.
      (should (<= (code-reader-guide--height) code-reader-chat-lines))
      (code-reader-ui-hide-panel view)
      (should-not (code-reader-chat--window view))
      (should-not (window-live-p panel)))))

(ert-deftest code-reader-test-key-table-is-shown-only-while-the-cursor-is-in-the-explanation ()
  "The bottom panel shows the key table on entering the explanation, and goes away once the
cursor moves in it.  Then the explanation takes the whole column again."
  (code-reader-test--with-panes 200 code-reader-test--window-sections
    (setq code-reader-guide--last-window src-win)
    (select-window exp-win)
    (code-reader-guide--post-command)
    (should code-reader-guide--shown)
    (should (eq (window-buffer (code-reader-chat--window view))
                (get-buffer code-reader-guide-buffer-name)))
    (with-current-buffer (window-buffer exp-win) (goto-char (point-min)))
    (code-reader-guide--post-command)
    (should-not code-reader-guide--shown)
    (should-not (code-reader-chat-panel-window))
    (should (= (nth 3 (window-edges exp-win)) (nth 3 (window-edges src-win))))))

(ert-deftest code-reader-test-leaving-the-panel-hides-it ()
  "Selecting the explanation again, after the question box was used, hides the panel."
  (code-reader-test--with-panes 200 code-reader-test--window-sections
    (code-reader-commands--install-pane-hooks view)
    (code-reader-chat-focus)
    (should (code-reader-chat-panel-window))
    (select-window exp-win)
    (code-reader-guide--post-command)
    (should-not (code-reader-chat-panel-window))
    (should (= (nth 3 (window-edges exp-win)) (nth 3 (window-edges src-win))))))

(ert-deftest code-reader-test-selecting-the-panel-shows-the-question-box ()
  "Selecting the panel while the key table is in it clears the table and shows the
question box, and what is typed in the box is not moved by the hook."
  (code-reader-test--with-panes 200 code-reader-test--window-sections
    (code-reader-commands--install-pane-hooks view)
    (setq code-reader-guide--last-window src-win)
    (select-window exp-win)
    (code-reader-guide--post-command)
    (should code-reader-guide--shown)
    (select-window (code-reader-chat-panel-window))
    (code-reader-guide--post-command)
    (let ((box (code-reader-chat--buffer-of view)))
      (should-not code-reader-guide--shown)
      (should (eq (window-buffer (code-reader-chat-panel-window)) box))
      (should (eq (current-buffer) box))
      (with-current-buffer box (insert "abc") (goto-char (point-min)))
      (code-reader-guide--post-command)
      (should (= (with-current-buffer box (point)) (point-min)))
      (should (equal (with-current-buffer box (buffer-string)) "abc")))))

(ert-deftest code-reader-test-chat-header-names-the-highlighted-section ()
  "The question box says which lines the next question is about."
  (code-reader-test--with-panes 200 code-reader-test--window-sections
    (code-reader-sync--highlight-active view (code-reader-session-section-by-id view "w-s2"))
    (should (string-match-p "About lines 11–30 · Setup"
                            (with-current-buffer (code-reader-chat--buffer-of view) header-line-format)))))

(ert-deftest code-reader-test-chat-sends-all-typed-text-wherever-point-is ()
  "Text typed in the box survives a redraw, and is sent whole even when point is at its start."
  (code-reader-test--with-panes 200 code-reader-test--window-sections
    (code-reader-sync--highlight-active view (code-reader-session-section-by-id view "w-s2"))
    (let ((sent nil))
      (unwind-protect
          (cl-letf (((symbol-function 'code-reader-transport-connect)
                     (lambda (callback) (funcall callback nil)))
                    ((symbol-function 'code-reader--send)
                     (lambda (request) (setq sent request))))
            (with-current-buffer (code-reader-chat--buffer-of view)
              (insert "what is DISTINCT?")
              (code-reader-chat-refresh view)
              (should (equal (code-reader-chat--input-text) "what is DISTINCT?"))
              (goto-char (point-min))
              (insert "Q: ")
              (code-reader-chat-send)
              (should (equal (plist-get sent :question) "Q: what is DISTINCT?"))
              (should (equal (code-reader-chat--input-text) ""))))
        (setq code-reader-chat--pending nil)))))

(ert-deftest code-reader-test-chat-question-is-a-follow-up-with-its-own-view ()
  "A question becomes a follow_up request for the section's lines, on a view of its own."
  (code-reader-test--with-panes 200 code-reader-test--window-sections
    (let* ((section (code-reader-session-section-by-id view "w-s2"))
           (request (code-reader-chat--request view section "Why?" "chat-1"))
           (target (plist-get request :target)))
      (should (equal (plist-get request :task) "follow_up"))
      (should (equal (plist-get request :question) "Why?"))
      (should (string-suffix-p "#chat-chat-1" (plist-get request :view)))
      (should (equal (plist-get target :start_line) 11))
      (should (equal (plist-get target :end_line) 30)))))

(ert-deftest code-reader-test-chat-answer-is-nested-under-its-section ()
  "An answer is a question nested under the section it was asked about."
  (code-reader-test--with-panes 200 code-reader-test--window-sections
    (setq code-reader-chat--pending (list (cons "chat-a" view)))
    (should-not (code-reader-chat-handle-event (list :type "result" :id "other-id")))
    (should (code-reader-chat-handle-event
             (code-reader-test--result
              "chat-a"
              (code-reader-test--with-followup code-reader-test--window-sections "w-s2"
                                               "Why?" "Because the tests say so.")
              :task "follow_up" :question "Why?" :answer "Because the tests say so."
              :target (list :start_line 11 :end_line 30))))
    (should-not code-reader-chat--pending)
    (should (equal (plist-get (code-reader-session-section-by-id view "w-s2") :id) "w-s2"))
    (with-current-buffer (code-reader-view-explanation-buffer view)
      (should (string-match-p "\\*\\* Question: Why\\?" (buffer-string)))
      (should (string-match-p "Because the tests say so\\." (buffer-string)))
      ;; The section is opened so the new question is in view. Its answer stays folded.
      (should-not (invisible-p (code-reader-test--text-pos "** Question: Why?")))
      (should (invisible-p (code-reader-test--text-pos "Because the tests say so."))))))

(ert-deftest code-reader-test-answer-keeps-the-cursor-where-it-was ()
  "An answer redraws the explanation, and the cursor stays on the line it was on."
  (let ((sections (list (code-reader-test--section "k-s1" 1 10 "One" "a1\na2\na3")
                        (code-reader-test--section "k-s2" 11 20 "Two" "b1\nb2\nb3"))))
    (code-reader-test--with-panes 30 sections
      (code-reader-sync--highlight-active view (code-reader-session-section-by-id view "k-s2"))
      ;; The reader opens the second section and puts the cursor on its second line.
      (with-selected-window exp-win
        (with-current-buffer (code-reader-view-explanation-buffer view)
          (goto-char (code-reader-test--heading-pos view "k-s2"))
          (org-cycle)
          (goto-char (code-reader-test--text-pos "b2"))
          (set-window-point exp-win (point))))
      (set-window-start exp-win (code-reader-test--heading-pos view "k-s1") t)
      ;; The question is about the section the cursor is in.
      (setq code-reader-chat--pending (list (cons "chat-k" view)))
      (should (code-reader-chat-handle-event
               (code-reader-test--result
                "chat-k"
                (code-reader-test--with-followup sections "k-s2" "Why?" "Because.")
                :task "follow_up" :question "Why?" :answer "Because."
                :target (list :start_line 11 :end_line 20))))
      ;; The cursor is still on its line, and in view after a real redisplay.
      (should (equal (code-reader-test--line-at exp-win (window-point exp-win)) "  b2"))
      (should (code-reader-ui--point-in-window-p (window-point exp-win) exp-win)))))

(ert-deftest code-reader-test-chat-focus-moves-to-the-question-box ()
  "The `a' key in the explanation pane moves to the question box."
  (code-reader-test--with-panes 200 code-reader-test--window-sections
    (select-window exp-win)
    (code-reader-chat-focus)
    (should (eq (selected-window) (code-reader-chat--window view)))))

(ert-deftest code-reader-test-chat-send-sends-the-question-and-clears-the-box ()
  "RET in the question box sends the question about the highlighted section, then clears the box."
  (code-reader-test--with-panes 200 code-reader-test--window-sections
    (code-reader-sync--highlight-active view (code-reader-session-section-by-id view "w-s2"))
    (let ((sent nil))
      (unwind-protect
          (cl-letf (((symbol-function 'code-reader-transport-connect)
                     (lambda (callback) (funcall callback nil)))
                    ((symbol-function 'code-reader--send)
                     (lambda (request) (setq sent request))))
            (with-current-buffer (code-reader-chat--buffer-of view)
              (goto-char (point-max))
              (insert "Explain more about this?")
              (code-reader-chat-send)
              (should (equal (plist-get sent :task) "follow_up"))
              (should (equal (plist-get sent :question) "Explain more about this?"))
              (should (= (length code-reader-chat--pending) 1))
              (should (equal (code-reader-chat--input-text) ""))))
        (setq code-reader-chat--pending nil)))))

(ert-deftest code-reader-test-jump-from-explanation-moves-the-source-window ()
  "A jump started in the explanation pane moves the source window, not only the buffer point."
  (code-reader-test--with-panes 200 code-reader-test--window-sections
    (set-window-point src-win (code-reader-test--line-pos source 150))
    (select-window exp-win)
    (code-reader-sync-jump view "w-s2")
    (should (eq (selected-window) exp-win))
    (should (= (with-current-buffer source (line-number-at-pos (window-point src-win) t)) 11))
    (should (= (with-current-buffer source (line-number-at-pos (point) t)) 11))
    (should (<= (window-start src-win) (code-reader-test--line-pos source 11)))))

(ert-deftest code-reader-test-active-section-is-a-fringe-bar-not-a-background ()
  "The active section is one fringe bar per line, and no overlay changes the text's face."
  (code-reader-test--with-panes 200 code-reader-test--window-sections
    (code-reader-sync--highlight-active view (code-reader-session-section-by-id view "w-s2"))
    (let* ((buffer (code-reader-view-explanation-buffer view))
           (marks (buffer-local-value 'code-reader-highlight--active-marks buffer)))
      (should (> (length marks) 0))
      (dolist (ov marks)
        (should-not (overlay-get ov 'face))
        (should (eq (car (get-text-property 0 'display (overlay-get ov 'before-string))) 'left-fringe))))))

(ert-deftest code-reader-test-redraw-keeps-one-set-of-marks ()
  "Redrawing the explanation keeps one set of marks on the active section, and none are left behind."
  (code-reader-test--with-panes 200 code-reader-test--window-sections
    (code-reader-sync--highlight-active view (code-reader-session-section-by-id view "w-s2"))
    (let* ((buffer (code-reader-view-explanation-buffer view))
           (count (length (buffer-local-value 'code-reader-highlight--active-marks buffer))))
      (code-reader-ui-render view t)
      (should (= (length (buffer-local-value 'code-reader-highlight--active-marks buffer)) count))
      (should (= (length (with-current-buffer buffer
                           (cl-remove-if-not (lambda (ov) (overlay-get ov 'code-reader))
                                             (overlays-in (point-min) (point-max)))))
                 count)))))

(ert-deftest code-reader-test-clearing-the-active-marks-removes-them ()
  "Clearing the active section removes every mark from the explanation buffer."
  (code-reader-test--with-panes 200 code-reader-test--window-sections
    (code-reader-sync--highlight-active view (code-reader-session-section-by-id view "w-s2"))
    (let ((buffer (code-reader-view-explanation-buffer view)))
      (code-reader-highlight-clear-active buffer)
      (should-not (buffer-local-value 'code-reader-highlight--active-marks buffer))
      (should-not (with-current-buffer buffer
                    (cl-some (lambda (ov) (overlay-get ov 'code-reader))
                             (overlays-in (point-min) (point-max))))))))

(ert-deftest code-reader-test-leaving-the-panes-clears-the-source-marks ()
  "Hiding or closing the explanation removes the fringe bars from the source buffer."
  (code-reader-test--with-panes 200 code-reader-test--window-sections
    (code-reader-sync-jump view "w-s2")
    (should (buffer-local-value 'code-reader-highlight--source-marks source))
    (code-reader-ui-hide-panel view)
    (should-not (buffer-local-value 'code-reader-highlight--source-marks source))
    (code-reader-ui-open view)
    (code-reader-sync-jump view "w-s2")
    (should (buffer-local-value 'code-reader-highlight--source-marks source))
    (code-reader-ui-close view)
    (should-not (buffer-local-value 'code-reader-highlight--source-marks source))))

(ert-deftest code-reader-test-entering-the-explanation-does-not-move-the-source ()
  "Showing the key guide on entering the explanation does not scroll the source.
A genuine scroll of the explanation still does."
  (code-reader-test--with-panes 200 code-reader-test--window-sections
    (code-reader-sync-jump view "w-s2")
    ;; The explanation is scrolled to another section, and the scroll sync follows it.
    (set-window-start exp-win (code-reader-test--heading-pos view "w-s4"))
    (code-reader-sync-explanation-scrolled view)
    (let ((source-start (window-start src-win)))
      (setq code-reader-guide--last-window src-win)
      (select-window exp-win)
      (code-reader-guide--post-command)
      (should code-reader-guide--shown)
      (code-reader-sync-explanation-scrolled view)
      (should (= (window-start src-win) source-start))
      ;; A genuine scroll of the explanation moves the source to the section at its top.
      (set-window-start exp-win (code-reader-test--heading-pos view "w-s6"))
      (code-reader-sync-explanation-scrolled view)
      (should (= (window-start src-win) (code-reader-test--line-pos source 101))))
    (code-reader-guide-hide)))

(ert-deftest code-reader-test-entering-the-explanation-puts-the-cursor-on-the-highlighted-section ()
  "Moving from the source into the explanation puts the cursor on the highlighted section.
The key guide does not hide again on the next command, which the cursor move could cause."
  (code-reader-test--with-panes 200 code-reader-test--window-sections
    (let ((src-win (code-reader-ui-source-window view)))
      (code-reader-sync--highlight-active view (code-reader-session-section-by-id view "w-s2"))
      (set-window-point exp-win (code-reader-test--heading-pos view "w-s1"))
      (setq code-reader-guide--last-window src-win)
      (select-window exp-win)
      (code-reader-guide--post-command)
      (should (= (window-point exp-win) (code-reader-test--heading-pos view "w-s2")))
      (should code-reader-guide--shown)
      ;; The next command, in the explanation pane, does not move the cursor.
      (code-reader-guide--post-command)
      (should code-reader-guide--shown))
    (code-reader-guide-hide)))

(ert-deftest code-reader-test-clicking-into-the-explanation-keeps-the-click-point ()
  "A click that enters the explanation keeps the cursor where it was pressed."
  (code-reader-test--with-panes 200 code-reader-test--window-sections
    (let ((src-win (code-reader-ui-source-window view))
          (pressed (code-reader-test--heading-pos view "w-s1")))
      (code-reader-sync--highlight-active view (code-reader-session-section-by-id view "w-s2"))
      (set-window-point exp-win pressed)
      (setq code-reader-guide--last-window src-win)
      (select-window exp-win)
      (let ((last-command-event (list 'mouse-1 (list exp-win 1 '(1 . 1) 0))))
        (code-reader-guide--post-command))
      (should (= (window-point exp-win) pressed)))
    (code-reader-guide-hide)))

(ert-deftest code-reader-test-entering-the-explanation-scrolls-to-a-highlighted-section-out-of-view ()
  "When the highlighted section is out of view, entering the explanation shows it at the top.
Sections are folded to one line each, so thirty of them are more than the pane shows."
  (let ((many (cl-loop for i from 1 to 30
                       collect (code-reader-test--section (format "m-s%d" i) (* 2 i) (* 2 i)
                                                          (format "Title %d" i) "Text."))))
    (code-reader-test--with-panes 100 many
      (let ((src-win (code-reader-ui-source-window view)))
        (code-reader-sync--highlight-active view (code-reader-session-section-by-id view "m-s30"))
        (with-current-buffer (code-reader-view-explanation-buffer view)
          (set-window-start exp-win (point-min) t)
          (set-window-point exp-win (point-min)))
        (setq code-reader-guide--last-window src-win)
        (select-window exp-win)
        (code-reader-guide--post-command)
        (should (= (window-start exp-win) (code-reader-test--heading-pos view "m-s30")))
        (should (= (window-point exp-win) (code-reader-test--heading-pos view "m-s30"))))
      (code-reader-guide-hide))))

;;; Saved explanations

(defun code-reader-test--saved-file (project-root state key model)
  "Write a saved whole-file explanation of lisp/sample.el, where the engine writes it.
It goes under PROJECT-ROOT's folder in STATE's cache, in the file's path, with KEY and
MODEL in its header.  Return its path."
  (let* ((folder (expand-file-name "lisp/sample.el"
                                   (expand-file-name (code-reader-cache-project-folder project-root)
                                                     (expand-file-name "cache/" state))))
         (path (expand-file-name (format "whole-file-English-%s.org" (substring key 0 8)) folder)))
    (make-directory folder t)
    (with-temp-file path
      (insert (format "#+TITLE: lisp/sample.el\n#+PROJECT: %s\n#+KEY: %s\n#+MODEL: %s\n"
                      project-root key model)
              "#+STARTUP: overview\n#+OPTIONS: ^:nil\n\n"
              "* Summary\n  :PROPERTIES:\n  :KIND: summary\n  :END:\n  A saved summary.\n\n"
              "* Lines 1–2 · Greet\n  :PROPERTIES:\n  :KIND: section\n  :SECTION_ID: saved-s1\n"
              "  :LINES: 1-2\n  :END:\n  A saved explanation.\n\n"))
    path))

(defmacro code-reader-test--with-saved-project (model-var &rest body)
  "Run BODY in a project with a source file, and a state directory that holds a saved explanation.
Binds `root', `file', `state', `key', `saved' (the saved file's path) and `buffer',
where the saved explanation's header names MODEL-VAR's value."
  (declare (indent 1))
  `(let* ((tmp (file-name-as-directory (make-temp-file "cr-saved-" t)))
          (root (directory-file-name (file-truename (expand-file-name "project" tmp))))
          (file (expand-file-name "lisp/sample.el" root))
          (state (file-name-as-directory (expand-file-name "state" tmp)))
          (key (make-string 64 ?b))
          (code-reader-state-directory state)
          (code-reader-explain-language "English")
          (code-reader-model nil)
          (buffer nil)
          (view nil)
          (saved-config (current-window-configuration))
          (sync-hook-present (memq #'code-reader-sync--on-window-scroll window-scroll-functions)))
     (unwind-protect
         (progn
           (make-directory (expand-file-name ".git" root) t)
           (make-directory (file-name-directory file) t)
           (with-temp-file file (insert "(defun a ())\n(defun b ())\n"))
           (let ((saved (code-reader-test--saved-file root state key ,model-var)))
             (setq buffer (find-file-noselect file))
             ,@body))
       (set-window-configuration saved-config)
       ;; Opening the pane installs the scroll sync for the whole session; take it back out,
       ;; so that the tests that follow see the scroll hook exactly as they did before.
       (unless sync-hook-present
         (remove-hook 'window-scroll-functions #'code-reader-sync--on-window-scroll))
       (when view (code-reader-session-dispose view))
       (when (buffer-live-p buffer)
         (with-current-buffer buffer (set-buffer-modified-p nil))
         (kill-buffer buffer))
       (delete-directory tmp t))))

(ert-deftest code-reader-test-cache-project-folder-matches-the-engine ()
  "The folder name is the one the engine gives the same project (`project_folder' in cache.py)."
  (should (equal (code-reader-cache-project-folder "/home/me/dotfiles") "dotfiles-ff7dbe"))
  (should (equal (code-reader-cache-project-folder "/Users/x/My Project!") "My-Project-8e8f06")))

(ert-deftest code-reader-test-open-shows-a-saved-explanation-without-the-engine ()
  "Opening a file whose explanation is saved shows it, and the engine is never asked."
  (code-reader-test--with-saved-project "default"
    (cl-letf (((symbol-function 'code-reader-transport-connect)
               (lambda (_callback) (error "The engine must not start"))))
      (with-current-buffer buffer (code-reader-open)))
    (setq view (code-reader-session-view-of buffer))
    (should (eq (code-reader-view-status view) 'cached))
    (should (equal (code-reader-view-explanation-key view) key))
    (should (equal (code-reader-view-cache-path view) saved))
    (should (equal (plist-get (car (code-reader-view-sections view)) :id) "saved-s1"))
    (should (equal (code-reader-view-task view) "explain_file"))))

(ert-deftest code-reader-test-a-saved-explanation-made-with-another-model-is-not-shown ()
  "A saved explanation made with another model is not shown, so the engine makes a new one."
  (code-reader-test--with-saved-project "sonnet"
    (setq view (code-reader-session-view-for buffer))
    (with-current-buffer buffer
      (should-not (code-reader-cache-find view)))))

;;; Deleting a question

(ert-deftest code-reader-test-d-deletes-the-question-at-point-after-a-yes-or-no ()
  "d asks yes or no.  No sends nothing.  Yes asks the engine to delete the question, and the
answer leaves the pane once the engine has done it."
  (code-reader-test--with-panes 200 code-reader-test--window-sections
    (let ((answered (code-reader-test--with-followup code-reader-test--window-sections
                                                     "w-s2" "Why?" "Because.")))
      (code-reader-session-apply-result view (code-reader-test--result "pane-1" answered))
      (code-reader-ui-render view))
    (should (equal (lookup-key code-reader-explanation-mode-map "d") #'code-reader-delete-question))
    (let ((sent nil))
      (with-current-buffer (code-reader-view-explanation-buffer view)
        (goto-char (code-reader-test--text-pos "** Question: Why?"))
        (cl-letf (((symbol-function 'y-or-n-p) (lambda (_prompt) nil))
                  ((symbol-function 'code-reader-transport-connect) (lambda (callback) (funcall callback nil)))
                  ((symbol-function 'code-reader--send) (lambda (request) (setq sent request))))
          (code-reader-delete-question)))
      (should-not sent)
      (should (string-match-p "\\*\\* Question: Why\\?" (with-current-buffer (code-reader-view-explanation-buffer view)
                                                         (buffer-string))))
      (with-current-buffer (code-reader-view-explanation-buffer view)
        (goto-char (code-reader-test--text-pos "** Question: Why?"))
        (cl-letf (((symbol-function 'y-or-n-p) (lambda (_prompt) t))
                  ((symbol-function 'code-reader-transport-connect) (lambda (callback) (funcall callback nil)))
                  ((symbol-function 'code-reader--send) (lambda (request) (setq sent request))))
          (code-reader-delete-question)))
      (should (equal (plist-get sent :task) "delete_question"))
      (should (equal (plist-get sent :question_at) "2026-11-22T10:00:00"))
      (should (equal (plist-get sent :explanation_key) code-reader-test--key))
      (should (= (length code-reader-session--delete-requests) 1))
      (code-reader-session-handle-event
       (code-reader-test--result (plist-get sent :id) code-reader-test--window-sections
                                 :task "delete_question"))
      (should-not code-reader-session--delete-requests)
      (with-current-buffer (code-reader-view-explanation-buffer view)
        (should-not (string-match-p "Why\\?" (buffer-string)))
        (should (string-match-p "Setup text\\." (buffer-string)))))))

(ert-deftest code-reader-test-d-outside-a-question-says-so-and-asks-nothing ()
  "d on a section heading, or on text that is not a question, is refused without asking."
  (code-reader-test--with-panes 200 code-reader-test--window-sections
    (with-current-buffer (code-reader-view-explanation-buffer view)
      (goto-char (code-reader-test--heading-pos view "w-s2"))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (_prompt) (error "must not ask"))))
        (should-error (code-reader-delete-question) :type 'user-error)))))

;;; Detail explanation

(defconst code-reader-test--detail-sections
  (list (append (code-reader-test--section "dt-s1" 1 2 "Greet" "Greets.")
                (list :detail (list (list 1 "Starts greet.")
                                    (list 2 "The docstring."))))
        (code-reader-test--section "dt-s2" 4 5 "Add" "Adds."))
  "Sections for the detail tests.  The first has a detail explanation; the second has none.")

(ert-deftest code-reader-test-D-and-s-are-bound-and-the-key-guide-lists-them ()
  "D explains the whole file in detail, s explains the highlighted section in detail, and the key guide says so."
  (should (eq (lookup-key code-reader-explanation-mode-map "D") #'code-reader-explain-detail))
  (should (eq (lookup-key code-reader-explanation-mode-map "s") #'code-reader-explain-section-detail))
  (let ((text (mapconcat #'substring-no-properties (code-reader-guide--lines) "\n")))
    (should (string-match-p "D: explain the whole file in detail" text))
    (should (string-match-p "s: explain this section in detail" text))))

(ert-deftest code-reader-test-D-asks-yes-or-no-and-sends-nothing-on-no ()
  "D asks before it explains the whole file, and a no starts nothing."
  (code-reader-test--with-panes 200 code-reader-test--window-sections
    (let ((sent nil) (asked nil))
      (unwind-protect
          (cl-letf (((symbol-function 'code-reader-transport-connect) (lambda (callback) (funcall callback nil)))
                    ((symbol-function 'code-reader--send) (lambda (request) (setq sent request)))
                    ((symbol-function 'y-or-n-p) (lambda (prompt) (setq asked prompt) nil)))
            (with-current-buffer (code-reader-view-explanation-buffer view)
              (code-reader-explain-detail))
            (should (string-match-p "Explain every line of the file in detail" asked))
            (should-not sent)
            (should-not code-reader-session--detail-requests)
            (should-not (code-reader-view-detail view)))
        (setq code-reader-session--detail-requests nil)))))

(ert-deftest code-reader-test-D-without-an-explanation-says-so-and-does-not-ask ()
  "D needs an explanation first, so it says so before it asks anything."
  (code-reader-test--with-panes 200 code-reader-test--window-sections
    (setf (code-reader-view-explanation-key view) nil)
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (_prompt) (error "must not ask"))))
      (with-current-buffer (code-reader-view-explanation-buffer view)
        (should-error (code-reader-explain-detail) :type 'user-error)))))

(ert-deftest code-reader-test-s-explains-only-the-highlighted-section-in-detail ()
  "s sends one explain_detail_section request for the highlighted section's lines alone, without asking."
  (code-reader-test--with-panes 200 code-reader-test--detail-sections
    (with-current-buffer source (goto-char (code-reader-test--line-pos source 2)))
    (code-reader-sync--run-point view)
    (let ((sent nil))
      (unwind-protect
          (cl-letf (((symbol-function 'code-reader-transport-connect) (lambda (callback) (funcall callback nil)))
                    ((symbol-function 'code-reader--send) (lambda (request) (setq sent request)))
                    ((symbol-function 'y-or-n-p) (lambda (_prompt) (error "must not ask"))))
            (with-current-buffer (code-reader-view-explanation-buffer view)
              (code-reader-explain-section-detail))
            (should (equal (plist-get sent :task) "explain_detail_section"))
            (should (equal (plist-get sent :explanation_key) code-reader-test--key))
            (should (= (plist-get (plist-get sent :target) :start_line) 1))
            (should (= (plist-get (plist-get sent :target) :end_line) 2))
            (should (string-match-p "#detail-" (plist-get sent :view)))
            (should (= (length code-reader-session--detail-requests) 1)))
        (setq code-reader-session--detail-requests nil)))))

(ert-deftest code-reader-test-evil-snipe-leaves-s-to-the-explanation-pane ()
  "evil-snipe takes s and S in normal and motion state, so the explanation pane turns it off.
Skipped when evil-snipe is not installed."
  (skip-unless (locate-library "evil-snipe"))
  (require 'evil-snipe)
  (unwind-protect
      (progn
        (evil-snipe-mode 1)
        (with-temp-buffer
          (code-reader-explanation-mode)
          (should-not evil-snipe-local-mode)
          (should-not evil-snipe-override-local-mode)))
    (evil-snipe-mode -1)))

(ert-deftest code-reader-test-C-is-bound-and-the-key-guide-lists-it ()
  "C collapses every section of the explanation, and the key guide lists it."
  (should (eq (lookup-key code-reader-explanation-mode-map "C") #'code-reader-collapse-all))
  (let ((text (mapconcat #'substring-no-properties (code-reader-guide--lines) "\n")))
    (should (string-match-p "C: collapse all sections" text))))

(ert-deftest code-reader-test-C-collapses-every-section-and-its-detail ()
  "C folds every section, with its text, questions and detail explanation, so only the headings show.
The point moves to a heading when the text under it was folded away."
  (code-reader-test--with-panes 200 code-reader-test--detail-sections
    (code-reader-ui-render view nil nil t)
    (with-current-buffer (code-reader-view-explanation-buffer view)
      (goto-char (code-reader-test--text-pos "Starts greet."))
      (should-not (invisible-p (code-reader-test--text-pos "Starts greet.")))
      (code-reader-collapse-all)
      (should (invisible-p (code-reader-test--text-pos "Starts greet.")))
      (should (invisible-p (code-reader-test--text-pos "Greets.")))
      (should-not (invisible-p (code-reader-test--heading-pos view "dt-s1")))
      (should-not (invisible-p (point)))
      (should (= (point) (code-reader-test--heading-pos view "dt-s1"))))))

(ert-deftest code-reader-test-collapsed-sections-stay-collapsed-on-redraw ()
  "A redraw after C keeps every section and detail folded."
  (code-reader-test--with-panes 200 code-reader-test--detail-sections
    (code-reader-ui-render view nil nil t)
    (with-current-buffer (code-reader-view-explanation-buffer view)
      (code-reader-collapse-all))
    (code-reader-ui-render view t)
    (with-current-buffer (code-reader-view-explanation-buffer view)
      (should (invisible-p (code-reader-test--text-pos "Starts greet.")))
      (should (invisible-p (code-reader-test--text-pos "Greets."))))))

(ert-deftest code-reader-test-the-source-cursor-opens-a-collapsed-detail-again ()
  "After C, moving the source cursor into a section with a detail opens it again, as it always does."
  (code-reader-test--with-panes 200 code-reader-test--detail-sections
    (code-reader-ui-render view nil nil t)
    (with-current-buffer (code-reader-view-explanation-buffer view)
      (code-reader-collapse-all))
    (with-current-buffer source (goto-char (code-reader-test--line-pos source 2)))
    (code-reader-sync--run-point view)
    (with-current-buffer (code-reader-view-explanation-buffer view)
      (should-not (invisible-p (code-reader-test--text-pos "The docstring."))))))

(ert-deftest code-reader-test-s-needs-a-highlighted-section ()
  "s says so when no section is highlighted, and starts nothing."
  (code-reader-test--with-panes 200 code-reader-test--detail-sections
    (with-current-buffer (code-reader-view-explanation-buffer view)
      (should-error (code-reader-explain-section-detail) :type 'user-error))
    (should-not code-reader-session--detail-requests)))

(ert-deftest code-reader-test-detail-request-covers-the-whole-file-on-its-own-view ()
  "D sends one explain_detail request for the whole file, naming the explanation, on a view of its own."
  (code-reader-test--with-panes 200 code-reader-test--window-sections
    (let ((sent nil))
      (unwind-protect
          (cl-letf (((symbol-function 'code-reader-transport-connect) (lambda (callback) (funcall callback nil)))
                    ((symbol-function 'code-reader--send) (lambda (request) (setq sent request)))
                    ((symbol-function 'y-or-n-p) (lambda (_prompt) t)))
            (with-current-buffer (code-reader-view-explanation-buffer view)
              (code-reader-explain-detail))
            (should (equal (plist-get sent :task) "explain_detail"))
            (should (equal (plist-get sent :explanation_key) code-reader-test--key))
            (should (= (plist-get (plist-get sent :target) :start_line) 1))
            (should (= (plist-get (plist-get sent :target) :end_line)
                       (cdr (code-reader-session-whole-file-lines source))))
            (should (string-match-p "#detail-" (plist-get sent :view)))
            (should (= (length code-reader-session--detail-requests) 1)))
        (setq code-reader-session--detail-requests nil)))))

(ert-deftest code-reader-test-detail-needs-an-explanation-and-is-not-started-twice ()
  "D says so when there is no explanation, and does not start a second detail while one runs."
  (code-reader-test--with-panes 200 code-reader-test--window-sections
    (let ((key (code-reader-view-explanation-key view)))
      (setf (code-reader-view-explanation-key view) nil)
      (should-error (code-reader-session-explain-detail view) :type 'user-error)
      (setf (code-reader-view-explanation-key view) key))
    (unwind-protect
        (cl-letf (((symbol-function 'code-reader-transport-connect) (lambda (_callback) nil)))
          (code-reader-session-explain-detail view)
          (should-error (code-reader-session-explain-detail view) :type 'user-error)
          (should (= (length code-reader-session--detail-requests) 1)))
      (setq code-reader-session--detail-requests nil))))

(ert-deftest code-reader-test-detail-progress-shows-in-the-header-and-the-result-opens-the-details ()
  "Progress shows how many calls are done.  The result puts the detail subsections in, opened."
  (code-reader-test--with-panes 200 code-reader-test--window-sections
    (push (cons "dt-1" view) code-reader-session--detail-requests)
    (code-reader-session-handle-event
     (list :type "progress" :id "dt-1" :phase "running" :elapsed_ms 1000 :output_chars 10
           :steps (list :done 2 :total 5)))
    (should (equal (plist-get (code-reader-view-detail view) :done) 2))
    (should (equal (plist-get (code-reader-view-detail view) :total) 5))
    (with-current-buffer (code-reader-view-explanation-buffer view)
      (should (string-match-p "Detail explanation running: 2 of 5 pieces done" header-line-format)))
    (code-reader-session-handle-event
     (code-reader-test--result "dt-1" code-reader-test--detail-sections :task "explain_detail"))
    (should-not code-reader-session--detail-requests)
    (should-not (code-reader-view-detail view))
    (with-current-buffer (code-reader-view-explanation-buffer view)
      (should (string-match-p "^\\*\\* Detail explanation$" (buffer-string)))
      (should-not (invisible-p (code-reader-test--text-pos "Starts greet.")))
      (should (string-match-p "Adds\\." (buffer-string))))))

(ert-deftest code-reader-test-detail-stays-folded-until-opened-and-keeps-its-state-on-redraw ()
  "A detail explanation starts folded under its section.  TAB opens it, and a redraw keeps it open."
  (code-reader-test--with-panes 200 code-reader-test--detail-sections
    ;; TAB is pressed in the explanation window, which org-cycle recentres.
    (with-selected-window exp-win
      (with-current-buffer (code-reader-view-explanation-buffer view)
        (should (invisible-p (code-reader-test--text-pos "Starts greet.")))
        (goto-char (code-reader-test--text-pos "Detail explanation"))
        (org-cycle)
        (should-not (invisible-p (code-reader-test--text-pos "Starts greet.")))))
    (code-reader-ui-render view t)
    (with-current-buffer (code-reader-view-explanation-buffer view)
      (should-not (invisible-p (code-reader-test--text-pos "Starts greet."))))))

(ert-deftest code-reader-test-d-on-a-detail-explanation-is-not-a-question ()
  "d on a detail explanation is refused: only questions can be deleted."
  (code-reader-test--with-panes 200 code-reader-test--detail-sections
    (with-current-buffer (code-reader-view-explanation-buffer view)
      (goto-char (code-reader-test--text-pos "Detail explanation"))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (_prompt) (error "must not ask"))))
        (should-error (code-reader-delete-question) :type 'user-error)))))

(ert-deftest code-reader-test-cancel-stops-a-running-detail ()
  "c cancels a detail explanation that runs for the view, and tells the engine."
  (code-reader-test--with-panes 200 code-reader-test--window-sections
    (push (cons "dt-2" view) code-reader-session--detail-requests)
    (let ((sent nil))
      (unwind-protect
          (cl-letf (((symbol-function 'code-reader-transport-connected-p) (lambda () t))
                    ((symbol-function 'code-reader--send) (lambda (request) (push request sent))))
            (should (code-reader-session-cancel view)))
        (setq code-reader-session--detail-requests nil))
      (should (equal (plist-get (car sent) :type) "cancel"))
      (should (equal (plist-get (car sent) :id) "dt-2")))))

(ert-deftest code-reader-test-detail-error-is-forgotten-and-the-explanation-kept ()
  "An error for a detail explanation stops the wait and keeps the explanation as it was."
  (code-reader-test--with-panes 200 code-reader-test--window-sections
    (push (cons "dt-3" view) code-reader-session--detail-requests)
    (code-reader-session-handle-event (list :type "error" :id "dt-3" :code "claude_failed" :message "boom"))
    (should-not code-reader-session--detail-requests)
    (should (eq (plist-get (code-reader-view-detail view) :status) 'failed))
    (with-current-buffer (code-reader-view-explanation-buffer view)
      (should (string-match-p "Setup text\\." (buffer-string))))))

(ert-deftest code-reader-test-D-shows-running-at-the-top-of-the-header-at-once ()
  "Pressing D puts the status at the start of the header, before the engine answers."
  (code-reader-test--with-panes 200 code-reader-test--window-sections
    (unwind-protect
        (cl-letf (((symbol-function 'code-reader-transport-connect) (lambda (_callback) nil))
                  ((symbol-function 'y-or-n-p) (lambda (_prompt) t)))
          (with-current-buffer (code-reader-view-explanation-buffer view)
            (code-reader-explain-detail)
            (should (string-prefix-p " Detail explanation running: starting" header-line-format))))
      (setq code-reader-session--detail-requests nil))))

(ert-deftest code-reader-test-detail-failure-stays-in-the-header-until-the-next-try ()
  "A failed detail explanation says why at the top of the header, until it is tried again."
  (code-reader-test--with-panes 200 code-reader-test--window-sections
    (unwind-protect
        (cl-letf (((symbol-function 'code-reader-transport-connect) (lambda (_callback) nil))
                  ((symbol-function 'y-or-n-p) (lambda (_prompt) t)))
          (push (cons "dt-4" view) code-reader-session--detail-requests)
          (code-reader-session-handle-event
           (list :type "error" :id "dt-4" :code "bad_request" :message "unsupported task"))
          (should (eq (plist-get (code-reader-view-detail view) :status) 'failed))
          (with-current-buffer (code-reader-view-explanation-buffer view)
            (should (string-match-p "Detail explanation failed: engine is out of date" header-line-format)))
          (cl-letf (((symbol-function 'y-or-n-p) (lambda (_prompt) t)))
            (with-current-buffer (code-reader-view-explanation-buffer view)
              (code-reader-explain-detail)))
          (should (eq (plist-get (code-reader-view-detail view) :status) 'running)))
      (setq code-reader-session--detail-requests nil))))

;;; Confirmations for commands that replace saved explanations

(ert-deftest code-reader-test-g-asks-yes-or-no-before-it-replaces-the-explanation ()
  "g asks first.  No keeps the saved explanation and asks Claude nothing; yes asks Claude."
  (code-reader-test--with-panes 200 code-reader-test--window-sections
    (setf (code-reader-view-task view) "explain_file")
    (let ((asked nil) (refreshed nil))
      (with-current-buffer (code-reader-view-explanation-buffer view)
        (cl-letf (((symbol-function 'y-or-n-p) (lambda (prompt) (setq asked prompt) nil))
                  ((symbol-function 'code-reader-session-refresh) (lambda (_view) (setq refreshed t))))
          (code-reader-refresh)))
      (should (string-match-p "Regenerate the explanation" asked))
      (should-not refreshed))
    (let ((refreshed nil))
      (with-current-buffer (code-reader-view-explanation-buffer view)
        (cl-letf (((symbol-function 'y-or-n-p) (lambda (_prompt) t))
                  ((symbol-function 'code-reader-session-refresh) (lambda (_view) (setq refreshed t))))
          (code-reader-refresh)))
      (should refreshed))))

(ert-deftest code-reader-test-g-with-nothing-to-refresh-asks-nothing ()
  "g on a view that has no explanation yet says so, and does not ask."
  (code-reader-test--with-panes 200 code-reader-test--window-sections
    (setf (code-reader-view-task view) nil)
    (with-current-buffer (code-reader-view-explanation-buffer view)
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (_prompt) (error "must not ask"))))
        (should-error (code-reader-refresh) :type 'user-error)))))

(ert-deftest code-reader-test-clear-cache-asks-yes-or-no-before-it-deletes-everything ()
  "Clearing the cache asks first.  No sends nothing; yes sends the clear request."
  (let ((sent nil))
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (_prompt) nil))
              ((symbol-function 'code-reader-commands--send-when-connected)
               (lambda (object) (setq sent object))))
      (code-reader-clear-cache))
    (should-not sent)
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (_prompt) t))
              ((symbol-function 'code-reader-commands--send-when-connected)
               (lambda (object) (setq sent object))))
      (code-reader-clear-cache))
    (should (equal sent '(:type "clear_cache")))))

(ert-deftest code-reader-test-r-refreshes-the-highlighted-section ()
  "The r key in the explanation pane is bound to the section refresh."
  (should (eq (lookup-key code-reader-explanation-mode-map "r") #'code-reader-refresh-section)))

(ert-deftest code-reader-test-section-refresh-covers-only-the-highlighted-lines ()
  "A section refresh asks for the highlighted section's lines only, on a view of its own."
  (code-reader-test--with-panes 200 code-reader-test--window-sections
    (code-reader-sync--highlight-active view (code-reader-session-section-by-id view "w-s2"))
    (let ((sent nil))
      (unwind-protect
          (cl-letf (((symbol-function 'code-reader-transport-connect)
                     (lambda (callback) (funcall callback nil)))
                    ((symbol-function 'code-reader--send)
                     (lambda (request) (setq sent request))))
            (code-reader-session-refresh-section view)
            (should (equal (plist-get sent :task) "explain_section"))
            (should (eq (plist-get sent :use_cache) :false))
            (should (= (plist-get (plist-get sent :target) :start_line) 11))
            (should (= (plist-get (plist-get sent :target) :end_line) 30))
            (should (string-match-p "#refresh-" (plist-get sent :view)))
            (should (= (length code-reader-session--section-requests) 1)))
        (setq code-reader-session--section-requests nil)))))

(ert-deftest code-reader-test-section-refresh-needs-a-highlighted-section ()
  "Refreshing with no highlighted section tells the reader what to do."
  (code-reader-test--with-panes 200 code-reader-test--window-sections
    (setf (code-reader-view-active-section-id view) nil)
    (should-error (code-reader-session-refresh-section view) :type 'user-error)))

(ert-deftest code-reader-test-section-refresh-replaces-only-that-explanation ()
  "The new explanation replaces its own section's text in the document, and no other."
  (code-reader-test--with-panes 200 code-reader-test--window-sections
    (setq code-reader-session--section-requests (list (cons "rf-1" view)))
    (should-not (code-reader-session--section-event (list :type "result" :id "other-id")))
    (should (code-reader-session--section-event
             (code-reader-test--result
              "rf-1"
              (code-reader-test--replace-explanation code-reader-test--window-sections "w-s2"
                                                     "A brand new explanation.")
              :explanation "A brand new explanation."
              :target (list :start_line 11 :end_line 30))))
    (should-not code-reader-session--section-requests)
    (with-current-buffer (code-reader-view-explanation-buffer view)
      (should (string-match-p "A brand new explanation\\." (buffer-string)))
      (should-not (string-match-p "Setup text\\." (buffer-string)))
      (should (string-match-p "Intro text\\." (buffer-string))))))

(ert-deftest code-reader-test-section-refresh-clears-only-its-own-questions ()
  "A section refresh resets that section's questions; the other sections keep theirs."
  (code-reader-test--with-panes 200 code-reader-test--window-sections
    (let ((asked (code-reader-test--with-followup
                  (code-reader-test--with-followup code-reader-test--window-sections
                                                   "w-s2" "Old question?" "An old answer.")
                  "w-s1" "Keep this?" "Kept.")))
      (code-reader-session-apply-result view (code-reader-test--result "pane-1" asked))
      (code-reader-ui-render view)
      (with-current-buffer (code-reader-view-explanation-buffer view)
        (should (string-match-p "Old question\\?" (buffer-string)))))
    (setq code-reader-session--section-requests (list (cons "rf-3" view)))
    (should (code-reader-session--section-event
             (code-reader-test--result
              "rf-3"
              (code-reader-test--replace-explanation
               (code-reader-test--with-followup code-reader-test--window-sections "w-s1" "Keep this?" "Kept.")
               "w-s2" "Fresh explanation.")
              :explanation "Fresh explanation."
              :target (list :start_line 11 :end_line 30))))
    (with-current-buffer (code-reader-view-explanation-buffer view)
      (should-not (string-match-p "Old question\\?" (buffer-string)))
      (should (string-match-p "Keep this\\?" (buffer-string)))
      (should (string-match-p "Fresh explanation\\." (buffer-string))))))

(ert-deftest code-reader-test-failed-section-refresh-is-forgotten ()
  "An error for a section refresh stops the wait and keeps the old explanation."
  (code-reader-test--with-panes 200 code-reader-test--window-sections
    (setq code-reader-session--section-requests (list (cons "rf-2" view)))
    (should (code-reader-session--section-event
             (list :type "error" :id "rf-2" :code "claude_failed" :message "boom")))
    (should-not code-reader-session--section-requests)
    (with-current-buffer (code-reader-view-explanation-buffer view)
      (should (string-match-p "Setup text\\." (buffer-string))))))

;;; Folding

(ert-deftest code-reader-test-sections-start-folded-and-tab-opens-them ()
  "Each section starts folded to its heading, the summary starts open, and TAB opens a section."
  (let* ((source (code-reader-test--source-buffer 12))
         (view (code-reader-session-view-for source)))
    (unwind-protect
        (progn
          (setf (code-reader-view-pending-id view) "fold-1"
                (code-reader-view-status view) 'queued)
          (code-reader-session-handle-event
           (code-reader-test--result
            "fold-1" (list (code-reader-test--section "fold-1-s1" 1 3 "First" "First explanation."))))
          (with-current-buffer (code-reader-view-explanation-buffer view)
            (should-not (invisible-p (code-reader-test--text-pos "T\u00f3m t\u1eaft.")))
            (should (invisible-p (code-reader-test--text-pos "First explanation.")))
            (goto-char (code-reader-test--heading-pos view "fold-1-s1"))
            (org-cycle)
            (should-not (invisible-p (code-reader-test--text-pos "First explanation.")))))
      (code-reader-session-dispose view)
      (kill-buffer source))))

(ert-deftest code-reader-test-redraw-keeps-open-sections-open ()
  "A redraw keeps a section the reader opened open, and the other sections folded."
  (code-reader-test--with-panes 200 code-reader-test--window-sections
    ;; TAB is pressed in the explanation window, so that is the window it recentres.
    (with-selected-window exp-win
      (with-current-buffer (code-reader-view-explanation-buffer view)
        (goto-char (code-reader-test--heading-pos view "w-s2"))
        (org-cycle)))
    (code-reader-ui-render view t)
    (with-current-buffer (code-reader-view-explanation-buffer view)
      (should-not (invisible-p (code-reader-test--text-pos "Setup text.")))
      (should (invisible-p (code-reader-test--text-pos "Intro text."))))))

(defun code-reader-test--line-at (window position)
  "Return the text of the line that POSITION is on, in WINDOW's buffer."
  (with-current-buffer (window-buffer window)
    (save-excursion
      (goto-char position)
      (buffer-substring-no-properties (line-beginning-position) (line-end-position)))))

(ert-deftest code-reader-test-redraw-keeps-the-window-top-and-the-cursor ()
  "A redraw keeps the line at the top of the window, and the cursor on its line when it is in view."
  (code-reader-test--with-panes 200 code-reader-test--window-sections
    ;; The reader opens the section, then puts the cursor on its text.
    (with-selected-window exp-win
      (with-current-buffer (code-reader-view-explanation-buffer view)
        (goto-char (code-reader-test--heading-pos view "w-s4"))
        (org-cycle)))
    (set-window-start exp-win (code-reader-test--heading-pos view "w-s4") t)
    (set-window-point exp-win (with-current-buffer (code-reader-view-explanation-buffer view)
                                (code-reader-test--text-pos "Body text.")))
    (let ((cursor-line (code-reader-test--line-at exp-win (window-point exp-win))))
      (code-reader-ui-render view t)
      (should (= (window-start exp-win) (code-reader-test--heading-pos view "w-s4")))
      (should (equal (code-reader-test--line-at exp-win (window-point exp-win)) cursor-line)))))

(ert-deftest code-reader-test-cursor-off-screen-goes-to-the-top-line ()
  "A cursor that was off screen is not brought back: a redraw puts it on the top line."
  (code-reader-test--with-panes 200 code-reader-test--window-sections
    (set-window-start exp-win (code-reader-test--heading-pos view "w-s4") t)
    (set-window-point exp-win (with-current-buffer (code-reader-view-explanation-buffer view)
                                (code-reader-test--text-pos "Intro text.")))
    (code-reader-ui-render view t)
    (should (= (window-start exp-win) (code-reader-test--heading-pos view "w-s4")))
    (should (= (window-point exp-win) (window-start exp-win)))))

(ert-deftest code-reader-test-a-new-explanation-is-placed-at-the-highlighted-section ()
  "After a new explanation arrives, the pane shows the highlighted section, not the source's middle."
  (code-reader-test--with-panes 200 code-reader-test--window-sections
    (code-reader-sync--highlight-active view (code-reader-session-section-by-id view "w-s6"))
    (setf (code-reader-view-pending-id view) "p-2"
          (code-reader-view-status view) 'queued)
    (code-reader-session-handle-event
     (code-reader-test--result "p-2" code-reader-test--window-sections))
    (should (= (window-start exp-win) (code-reader-test--heading-pos view "w-s6")))))

(ert-deftest code-reader-test-moving-the-cursor-brings-its-section-into-the-explanation ()
  "Moving the source cursor to a section out of view scrolls the explanation to that section."
  (code-reader-test--with-panes 200 code-reader-test--window-sections
    (set-window-start exp-win (code-reader-test--heading-pos view "w-s1") t)
    (with-current-buffer source (goto-char (code-reader-test--line-pos source 150)))
    (code-reader-sync--run-point view)
    (should (equal (code-reader-view-active-section-id view) "w-s6"))
    (should (= (window-start exp-win) (code-reader-test--heading-pos view "w-s6")))))

(ert-deftest code-reader-test-opening-the-reader-shows-no-question-box ()
  "Opening the reader shows only the explanation; the question box is on screen only while
the cursor is in it, and reopening does not make a panel."
  (code-reader-test--with-panes 200 code-reader-test--window-sections
    (should-not (code-reader-chat--window view))
    (code-reader-ui-open view)
    (should-not (code-reader-chat--window view))
    (should (buffer-live-p (code-reader-chat--buffer-of view)))))

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

(ert-deftest code-reader-test-header-names-the-status ()
  "The header names the status and the Claude session."
  (let* ((source (code-reader-test--source-buffer 4))
         (view (code-reader-session-view-for source)))
    (unwind-protect
        (progn
          (setf (code-reader-view-status view) 'queued
                (code-reader-view-task view) "explain_file"
                (code-reader-view-claude-session view) "resumed")
          (should (string-match-p "queued" (code-reader-ui-header-string view)))
          (should (string-match-p "Claude: resumed" (code-reader-ui-header-string view))))
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
  "Opening shows source, explanation and question box; closing restores the original windows."
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

(ert-deftest code-reader-test-layout-pieces-do-not-look-like-a-scroll ()
  "Opening the layout (explanation, key guide, question box) records the pane's size, so the
scroll sync does not read the layout as a scroll."
  (code-reader-test--with-panes 200 code-reader-test--window-sections
    (should (equal (code-reader-view-synced-exp-size view)
                   (code-reader-session-window-size exp-win)))))

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
    (should (cl-some (lambda (ov) (overlay-get ov 'code-reader)) (with-current-buffer source
                                                                 (overlays-in (point-min) (point-max)))))
    (should (equal (code-reader-view-sync-target view) "w-s2"))))

(ert-deftest code-reader-test-moving-the-cursor-line-by-line-moves-the-explanation-to-its-section ()
  "Moving the source cursor one line at a time moves the explanation when the cursor enters
a new section, even when that section is already in view."
  (code-reader-test--with-panes 200 code-reader-test--window-sections
    (set-window-start exp-win (code-reader-test--heading-pos view "w-s1") t)
    ;; Premise: w-s2's heading is already on screen, below w-s1's.
    (should (code-reader-ui--point-in-window-p (code-reader-test--heading-pos view "w-s2") exp-win))
    ;; Lines 9 and 10 are in w-s1; line 11 starts w-s2.
    (dolist (line '(9 10 11))
      (with-current-buffer source (goto-char (code-reader-test--line-pos source line)))
      (code-reader-sync--run-point view))
    (should (equal (code-reader-view-active-section-id view) "w-s2"))
    (should (= (window-start exp-win) (code-reader-test--heading-pos view "w-s2")))))

(ert-deftest code-reader-test-a-scroll-caused-by-the-cursor-is-left-to-the-cursor-sync ()
  "When moving the cursor scrolls the source, the cursor's section decides the explanation.
The middle of the scrolled source is not used, because the cursor sync takes the cursor's section."
  (code-reader-test--with-panes 200 code-reader-test--window-sections
    (with-current-buffer source
      (goto-char (code-reader-test--line-pos source 60))
      (code-reader-sync--post-command))
    (set-window-start src-win (code-reader-test--line-pos source 50))
    (code-reader-sync--on-window-scroll src-win 50)
    (should (timerp (code-reader-view-point-timer view)))
    (should-not (code-reader-view-scroll-timer view))))

(ert-deftest code-reader-test-cursor-sync-highlights-section-at-point ()
  "Moving point in the source highlights the containing section, and brings it into view."
  (code-reader-test--with-panes 200 code-reader-test--window-sections
    (with-current-buffer source
      (goto-char (code-reader-test--line-pos source 42)))
    (code-reader-sync--run-point view)
    (should (equal (code-reader-view-active-section-id view) "w-s5"))
    (should (= (window-start exp-win) (code-reader-test--heading-pos view "w-s5")))))

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

;;; Detail lines in the sync

(defun code-reader-test--active-marks (view)
  "Return the overlays that mark VIEW's active highlight in its explanation buffer."
  (with-current-buffer (code-reader-view-explanation-buffer view)
    code-reader-highlight--active-marks))

(defun code-reader-test--marked-texts (marks)
  "Return the text of the line under each overlay in MARKS, in order."
  (mapcar (lambda (overlay)
            (with-current-buffer (overlay-buffer overlay)
              (save-excursion
                (goto-char (overlay-start overlay))
                (buffer-substring-no-properties (line-beginning-position) (line-end-position)))))
          marks))

(defun code-reader-test--source-mark-lines (source)
  "Return the absolute line numbers marked as the explained range in SOURCE."
  (with-current-buffer source
    (mapcar (lambda (overlay) (line-number-at-pos (overlay-start overlay) t))
            code-reader-highlight--source-marks)))

(ert-deftest code-reader-test-source-cursor-on-a-detail-line-selects-only-that-entry ()
  "With the detail open, the cursor on a line that has a detail entry selects that entry, not its section."
  (code-reader-test--with-panes 200 code-reader-test--detail-sections
    (code-reader-ui-render view nil nil t)
    (with-current-buffer source (goto-char (code-reader-test--line-pos source 2)))
    (code-reader-sync--run-point view)
    (should (= (code-reader-view-active-detail-line view) 2))
    (should (equal (code-reader-view-active-section-id view) "dt-s1"))
    ;; The bars cover the entry, its item line and explanation, and nothing else.
    (let ((texts (code-reader-test--marked-texts (code-reader-test--active-marks view))))
      (should (= (length texts) 2))
      (should (equal (car texts) "  - 2")))
    ;; The explanation pane is placed at the entry, so the selected line is on screen.
    (should (with-current-buffer (code-reader-view-explanation-buffer view)
              (code-reader-ui--point-in-window-p (code-reader-test--text-pos "  - 2\n") exp-win)))))

(ert-deftest code-reader-test-cursor-into-a-folded-section-opens-its-detail ()
  "Moving the source cursor into a section whose detail explanation is folded opens the detail,
and selects the line under the cursor in it."
  (code-reader-test--with-panes 200 code-reader-test--detail-sections
    ;; Premise: the section and its detail start folded.
    (with-current-buffer (code-reader-view-explanation-buffer view)
      (should (invisible-p (code-reader-test--text-pos "The docstring."))))
    (with-current-buffer source (goto-char (code-reader-test--line-pos source 2)))
    (code-reader-sync--run-point view)
    (with-current-buffer (code-reader-view-explanation-buffer view)
      (should-not (invisible-p (code-reader-test--text-pos "The docstring."))))
    (should (= (code-reader-view-active-detail-line view) 2))
    (should (equal (code-reader-view-active-section-id view) "dt-s1"))
    (should (with-current-buffer (code-reader-view-explanation-buffer view)
              (code-reader-ui--point-in-window-p (code-reader-test--text-pos "  - 2\n") exp-win)))))

(ert-deftest code-reader-test-cursor-into-a-section-without-detail-leaves-it-folded ()
  "A section with no detail explanation is not opened by the cursor."
  (code-reader-test--with-panes 200 code-reader-test--detail-sections
    (with-current-buffer source (goto-char (code-reader-test--line-pos source 4)))
    (code-reader-sync--run-point view)
    (should (equal (code-reader-view-active-section-id view) "dt-s2"))
    (with-current-buffer (code-reader-view-explanation-buffer view)
      (should (invisible-p (code-reader-test--text-pos "Adds."))))))

(ert-deftest code-reader-test-a-detail-opened-by-the-cursor-stays-open-on-redraw ()
  "A detail the cursor opened stays open after the explanation is redrawn, with its line selected."
  (code-reader-test--with-panes 200 code-reader-test--detail-sections
    (with-current-buffer source (goto-char (code-reader-test--line-pos source 2)))
    (code-reader-sync--run-point view)
    (code-reader-ui-render view t)
    (with-current-buffer (code-reader-view-explanation-buffer view)
      (should-not (invisible-p (code-reader-test--text-pos "The docstring."))))
    (let ((texts (code-reader-test--marked-texts (code-reader-test--active-marks view))))
      (should (equal (car texts) "  - 2")))))

(ert-deftest code-reader-test-the-cursor-reopens-a-detail-the-reader-closed ()
  "Moving the cursor within a section opens its detail again, even after the reader folded it."
  (code-reader-test--with-panes 200 code-reader-test--detail-sections
    (with-current-buffer source (goto-char (code-reader-test--line-pos source 2)))
    (code-reader-sync--run-point view)
    (with-current-buffer (code-reader-view-explanation-buffer view)
      (goto-char (code-reader-test--text-pos "** Detail explanation"))
      (org-fold-hide-entry))
    (with-current-buffer source (goto-char (code-reader-test--line-pos source 1)))
    (code-reader-sync--run-point view)
    (with-current-buffer (code-reader-view-explanation-buffer view)
      (should-not (invisible-p (code-reader-test--text-pos "Starts greet.")))
      (should (= (code-reader-view-active-detail-line view) 1)))))

(ert-deftest code-reader-test-explanation-point-on-a-detail-line-marks-only-that-source-line ()
  "Moving point in the explanation onto a detail line marks that one source line, not its section."
  (code-reader-test--with-panes 200 code-reader-test--detail-sections
    (code-reader-ui-render view nil nil t)
    (with-current-buffer (code-reader-view-explanation-buffer view)
      (goto-char (code-reader-test--text-pos "The docstring.")))
    (code-reader-sync--run-explanation-point view)
    (should (= (code-reader-view-active-detail-line view) 2))
    (should (equal (code-reader-view-active-section-id view) "dt-s1"))
    (should (equal (code-reader-test--source-mark-lines source) '(2)))
    (should (code-reader-ui--point-in-window-p (code-reader-test--line-pos source 2) src-win))))

(ert-deftest code-reader-test-explanation-point-off-the-detail-leaves-the-source-alone ()
  "Point on a section's own text, rather than on a detail line, does not change the source marks."
  (code-reader-test--with-panes 200 code-reader-test--detail-sections
    (code-reader-ui-render view nil nil t)
    (with-current-buffer (code-reader-view-explanation-buffer view)
      (goto-char (code-reader-test--text-pos "Greets.")))
    (code-reader-sync--run-explanation-point view)
    (should-not (code-reader-view-active-detail-line view))
    (should-not (code-reader-test--source-mark-lines source))))

(ert-deftest code-reader-test-explanation-scroll-on-a-detail-line-marks-only-that-line ()
  "Scrolling the explanation while its point is on a detail line marks only that source line."
  (code-reader-test--with-panes 200 code-reader-test--detail-sections
    (code-reader-ui-render view nil nil t)
    (set-window-start exp-win (code-reader-test--heading-pos view "dt-s1"))
    (with-current-buffer (code-reader-view-explanation-buffer view)
      (set-window-point exp-win (code-reader-test--text-pos "The docstring.")))
    (code-reader-sync-explanation-scrolled view)
    (should (equal (code-reader-test--source-mark-lines source) '(2)))))

(ert-deftest code-reader-test-RET-on-a-detail-line-jumps-to-that-line-only ()
  "RET on a detail line moves the source point to that line and marks only that line."
  (code-reader-test--with-panes 200 code-reader-test--detail-sections
    (code-reader-ui-render view nil nil t)
    (with-current-buffer (code-reader-view-explanation-buffer view)
      (goto-char (code-reader-test--text-pos "The docstring."))
      (code-reader-sync-jump-at-point))
    (should (= (with-current-buffer source (line-number-at-pos (point) t)) 2))
    (should (= (window-point src-win) (code-reader-test--line-pos source 2)))
    (should (equal (code-reader-test--source-mark-lines source) '(2)))
    (should (= (code-reader-view-active-detail-line view) 2))))

(ert-deftest code-reader-test-redraw-keeps-the-selected-detail-line ()
  "A redraw of the explanation keeps the selected detail line marked, and only that line."
  (code-reader-test--with-panes 200 code-reader-test--detail-sections
    (code-reader-ui-render view nil nil t)
    (with-current-buffer source (goto-char (code-reader-test--line-pos source 2)))
    (code-reader-sync--run-point view)
    (code-reader-ui-render view t)
    (let ((texts (code-reader-test--marked-texts (code-reader-test--active-marks view))))
      (should (= (length texts) 2))
      (should (equal (car texts) "  - 2")))))

(ert-deftest code-reader-test-explanation-point-moves-are-synced-through-the-pane-hook ()
  "The explanation pane has its own post-command sync, which schedules the detail sync."
  (code-reader-test--with-panes 200 code-reader-test--detail-sections
    (code-reader-ui-render view nil nil t)
    (code-reader-commands--install-pane-hooks view)
    (unwind-protect
        (with-current-buffer (code-reader-view-explanation-buffer view)
          (should (memq #'code-reader-sync--explanation-post-command post-command-hook))
          (goto-char (code-reader-test--text-pos "The docstring."))
          (code-reader-sync--explanation-post-command)
          (should (timerp (code-reader-view-explanation-timer view))))
      (when (timerp (code-reader-view-explanation-timer view))
        (cancel-timer (code-reader-view-explanation-timer view))))))

(ert-deftest code-reader-test-entering-the-explanation-lands-on-the-selected-detail-line ()
  "Entering the explanation from the source puts the cursor on the selected detail line."
  (code-reader-test--with-panes 200 code-reader-test--detail-sections
    (code-reader-ui-render view nil nil t)
    (with-current-buffer source (goto-char (code-reader-test--line-pos source 2)))
    (code-reader-sync--run-point view)
    (code-reader-sync-enter-explanation view)
    (with-current-buffer (code-reader-view-explanation-buffer view)
      (should (= (point) (code-reader-test--text-pos "  - 2\n"))))))

(ert-deftest code-reader-test-detail-arrival-selects-the-detail-line-under-the-cursor ()
  "When a detail explanation arrives, the detail line under the source cursor is selected at once."
  (code-reader-test--with-panes 200 code-reader-test--window-sections
    (with-current-buffer source (goto-char (code-reader-test--line-pos source 2)))
    (push (cons "dt-arrive" view) code-reader-session--detail-requests)
    (code-reader-session-handle-event
     (code-reader-test--result "dt-arrive" code-reader-test--detail-sections :task "explain_detail"))
    (should-not code-reader-session--detail-requests)
    (should (= (code-reader-view-active-detail-line view) 2))
    (should (equal (code-reader-view-active-section-id view) "dt-s1"))
    (let ((texts (code-reader-test--marked-texts (code-reader-test--active-marks view))))
      (should (= (length texts) 2))
      (should (equal (car texts) "  - 2")))))

(defconst code-reader-test--long-detail-sections
  (list (append (code-reader-test--section "lg-s1" 1 200 "Long"
                                           (mapconcat (lambda (i) (format "Explanation line %d." i))
                                                      (number-sequence 1 60) "\n"))
                (list :detail (list (list 100 "Explains line 100.")
                                    (list 101 "Explains line 101.")))))
  "One long section whose detail explains a line far below its top, so that centring shows.")

(ert-deftest code-reader-test-selected-detail-line-is-shown-in-the-middle-of-the-explanation ()
  "The detail line under the source cursor is on the middle row of the explanation pane,
so the lines around it are in view too."
  (code-reader-test--with-panes 200 code-reader-test--long-detail-sections
    (code-reader-ui-render view nil nil t)
    (with-current-buffer source (goto-char (code-reader-test--line-pos source 100)))
    (code-reader-sync--run-point view)
    (should (= (code-reader-view-active-detail-line view) 100))
    (with-current-buffer (code-reader-view-explanation-buffer view)
      (should (> (window-start exp-win) (point-min)))
      (should (= (count-screen-lines (window-start exp-win)
                                     (code-reader-test--text-pos "  - 100\n") nil exp-win)
                 (/ (window-body-height exp-win) 2))))))

(ert-deftest code-reader-test-selected-explanation-line-centres-its-source-line ()
  "A detail line the reader points at in the explanation is on the middle row of the source pane."
  (code-reader-test--with-panes 200 code-reader-test--long-detail-sections
    (code-reader-ui-render view nil nil t)
    (with-current-buffer (code-reader-view-explanation-buffer view)
      (goto-char (code-reader-test--text-pos "Explains line 100.")))
    (code-reader-sync--run-explanation-point view)
    (should (= (code-reader-view-active-detail-line view) 100))
    (with-current-buffer source
      (should (> (window-start src-win) (point-min)))
      (should (= (count-screen-lines (window-start src-win)
                                     (code-reader-test--line-pos source 100) nil src-win)
                 (/ (window-body-height src-win) 2))))))

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
              (should (equal (plist-get section :end-line) 4)))
            ;; The explanation is an Org document, and the cache keeps that document.
            (should (string-match-p "^\\* Lines 1–4" (code-reader-view-document view)))
            (should (directory-files-recursively (expand-file-name "state/cache/" tmp) "\\.org\\'"))
            ;; The engine reports the file it stored the explanation in, and it exists.
            (should (file-exists-p (code-reader-view-cache-path view)))
            ;; Emacs finds the file the engine wrote, by the names it computes itself.
            (should (equal (plist-get (code-reader-cache-find view) :key)
                           (code-reader-view-explanation-key view)))
            ;; A question is nested under its section, in the document and in the cache file.
            (let ((chat-id "e2e-chat"))
              (setq code-reader-chat--pending (list (cons chat-id view)))
              (code-reader--send (code-reader-chat--request view (car (code-reader-view-sections view))
                                                            "What does it do?" chat-id))
              (should (code-reader-test--wait (lambda () (null code-reader-chat--pending)) 120))
              (should (string-match-p "\\*\\* Question: What does it do\\?" (code-reader-view-document view)))
              (let ((cached (car (directory-files-recursively (expand-file-name "state/cache/" tmp)
                                                              "\\.org\\'"))))
                (should (string-match-p "\\*\\* Question: What does it do\\?"
                                      (with-temp-buffer
                                        (insert-file-contents cached)
                                        (buffer-string))))
              ;; A line-by-line detail, from the same engine, is kept in the same file with the question.
              (code-reader-session-explain-detail view)
              (should (code-reader-test--wait
                       (lambda () (string-match-p "Detail explanation" (or (code-reader-view-document view) "")))
                       120))
              (should-not (code-reader-view-detail view))
              (should (string-match-p "^  - 1$" (code-reader-view-document view)))
              (should (string-match-p "\\*\\* Question: What does it do\\?" (code-reader-view-document view)))
              (should (string-match-p "\\*\\* Detail explanation"
                                      (with-temp-buffer
                                        (insert-file-contents cached)
                                        (buffer-string)))))))
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
