;;; code-reader-ui.el --- Two-pane layout and explanation buffer for Code Reader -*- lexical-binding: t; -*-

;;; Commentary:

;; Layout and rendering.  The source buffer stays in the left window and the
;; explanation buffer `*code-reader: <basename>*' opens in a right window.  The
;; window configuration from before the first open is saved, so closing restores
;; the original layout exactly.
;;
;; The explanation is an Org document written by the engine (engine/org.py), and
;; the pane is `org-mode'.  Each section is a top-level heading, and the questions
;; asked about it are nested under the heading, so TAB folds and unfolds them.  The
;; sections' text carries the property `code-reader-section-id', and each section's
;; heading and end markers are kept in the view for the sync and jump commands.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'org)
(require 'code-reader-transport)
(require 'code-reader-session)
(require 'code-reader-highlight)

(declare-function code-reader-sync-jump-at-point "code-reader-sync")
(declare-function code-reader-sync-mouse-jump "code-reader-sync" (event))
(declare-function code-reader-refresh "code-reader-commands")
(declare-function code-reader-cancel "code-reader-commands")
(declare-function code-reader-toggle-panel "code-reader-commands")
(declare-function code-reader-close "code-reader-commands")
(declare-function evil-set-initial-state "evil-core" (mode state))
(declare-function evil-define-key* "evil-core"
                  (state keymap key def &rest bindings))
(declare-function evil-org-mode "evil-org" (&optional arg))
(declare-function code-reader-chat-show "code-reader-chat" (view explanation-window))
(declare-function code-reader-chat-hide "code-reader-chat" (view))
(declare-function code-reader-chat-focus "code-reader-chat" ())
(declare-function code-reader-chat--ensure-buffer "code-reader-chat" (view))
(declare-function code-reader-copy-cache-path "code-reader-commands" ())
(declare-function code-reader-delete-question "code-reader-commands" ())
(declare-function code-reader-refresh-section "code-reader-commands" ())
(declare-function code-reader-explain-detail "code-reader-commands" ())
(declare-function code-reader-explain-section-detail "code-reader-commands" ())
(declare-function code-reader-collapse-all "code-reader-commands" ())

;;; Window lookup

(defun code-reader-ui-source-window (view)
  "Return the window showing VIEW's source buffer, or nil."
  (get-buffer-window (code-reader-view-source-buffer view)))

(defun code-reader-ui-explanation-window (view)
  "Return the window showing VIEW's explanation buffer, or nil."
  (let ((buffer (code-reader-view-explanation-buffer view)))
    (and (buffer-live-p buffer) (get-buffer-window buffer))))

;;; Explanation mode

(defun code-reader-ui--answer-drawer-pos ()
  "Return the position of the :ANSWER: line of the question about a line that point is on, or nil.
Point is on such a question when it is on the question's line, on its :ANSWER: line, or in its answer."
  (save-excursion
    (beginning-of-line)
    (cond
     ((looking-at "^[ \t]+Question about line [0-9]+ (asked ")
      (forward-line 1)
      (and (looking-at "^[ \t]+:ANSWER:[ \t]*$") (point)))
     ((looking-at "^[ \t]+:ANSWER:[ \t]*$") (point))
     (t
      (catch 'found
        (while (= (forward-line -1) 0)
          (cond
           ((looking-at "^[ \t]+:ANSWER:[ \t]*$") (throw 'found (point)))
           ((or (looking-at "^  - [0-9]") (looking-at "^\\*")
                (looking-at "^[ \t]+:END:[ \t]*$") (looking-at "^[ \t]+Question about line"))
            (throw 'found nil))))
        nil)))))

(defun code-reader-explanation-tab ()
  "TAB in the explanation pane: fold or unfold what point is on.
A detail item is folded from the start of its line, because Org folds a list item only from
there, and point stays where it was.  A question about a line is folded by its answer drawer,
from anywhere in the question.  Anywhere else TAB is Org's own TAB."
  (interactive)
  (let ((answer (code-reader-ui--answer-drawer-pos)))
    (cond
     ((org-at-item-p)
      (save-excursion
        (beginning-of-line)
        (org-cycle)))
     (answer
      (save-excursion
        (goto-char answer)
        (org-cycle)))
     (t (org-cycle)))))

(defun code-reader-ui--item-folded-p ()
  "Return non-nil when point is on a detail item whose explanation is folded away."
  (save-excursion
    (beginning-of-line)
    (and (org-at-item-p)
         (= (forward-line 1) 0)
         (not (eobp))
         (invisible-p (point)))))

(defvar code-reader-explanation-mode-map
  (let ((map (make-sparse-keymap)))
    ;; Everything else (folding with TAB, Org's own motion) is Org's.
    (set-keymap-parent map org-mode-map)
    (define-key map (kbd "RET") #'code-reader-sync-jump-at-point)
    (define-key map [mouse-1] #'code-reader-sync-mouse-jump)
    (define-key map (kbd "TAB") #'code-reader-explanation-tab)
    ;; The Tab key can arrive as the tab event rather than as TAB, so both are bound.
    (define-key map [tab] #'code-reader-explanation-tab)
    (define-key map (kbd "<backtab>") #'org-shifttab)
    (define-key map "g" #'code-reader-refresh)
    (define-key map "c" #'code-reader-cancel)
    (define-key map "t" #'code-reader-toggle-panel)
    (define-key map "q" #'code-reader-close)
    (define-key map "a" #'code-reader-chat-focus)
    (define-key map "r" #'code-reader-refresh-section)
    (define-key map "p" #'code-reader-copy-cache-path)
    (define-key map "d" #'code-reader-delete-question)
    (define-key map "D" #'code-reader-explain-detail)
    (define-key map "s" #'code-reader-explain-section-detail)
    (define-key map "C" #'code-reader-collapse-all)
    map)
  "Keymap for `code-reader-explanation-mode'.")

(define-derived-mode code-reader-explanation-mode org-mode "Code-Reader"
  "Major mode for the Code Reader explanation pane: an Org document.
Each section is a heading.  TAB folds and unfolds it, and the questions asked
about it are nested under it.  RET or mouse-1 on a section jumps to its source
lines.  g refreshes the explanation, r refreshes the highlighted section, D explains
the whole file in detail (after a yes or no), s explains the highlighted section in
detail, C collapses every section, a asks about the highlighted line or section,
c cancels a running request,
t toggles the panel and q closes the view.
Evil users get the same keys in motion state."
  (setq-local truncate-lines nil)
  (setq buffer-read-only t)
  (visual-line-mode 1))

(defun code-reader-ui--plain-org-keys ()
  "Turn off evil-org in the explanation pane, so only the keys above apply there."
  (when (bound-and-true-p evil-org-mode)
    (evil-org-mode -1)))

(add-hook 'code-reader-explanation-mode-hook #'code-reader-ui--plain-org-keys)

(with-eval-after-load 'evil
  (when (fboundp 'evil-set-initial-state)
    (evil-set-initial-state 'code-reader-explanation-mode 'motion))
  (when (fboundp 'evil-define-key*)
    (evil-define-key* 'motion code-reader-explanation-mode-map
      (kbd "RET") #'code-reader-sync-jump-at-point
      (kbd "TAB") #'code-reader-explanation-tab
      [tab] #'code-reader-explanation-tab
      (kbd "<backtab>") #'org-shifttab
      "g" #'code-reader-refresh
      "c" #'code-reader-cancel
      "t" #'code-reader-toggle-panel
      "a" #'code-reader-chat-focus
      "r" #'code-reader-refresh-section
      "p" #'code-reader-copy-cache-path
      "d" #'code-reader-delete-question
      "D" #'code-reader-explain-detail
      "s" #'code-reader-explain-section-detail
      "C" #'code-reader-collapse-all
      "q" #'code-reader-close)))

;; evil-snipe binds s and S in normal and motion state, in every buffer, and its keymap
;; comes before the pane's own keys, so s would start a snipe instead of the section detail.
;; evil-snipe skips the modes in `evil-snipe-disabled-modes' whenever it turns on in a buffer.
;; The mode hook is too early for this, because evil-snipe turns on after it.
(defvar evil-snipe-disabled-modes)
(with-eval-after-load 'evil-snipe
  (add-to-list 'evil-snipe-disabled-modes 'code-reader-explanation-mode))

(defun code-reader-ui-explanation-buffer (view)
  "Return VIEW's explanation buffer, creating it when needed."
  (let ((buffer (code-reader-view-explanation-buffer view)))
    (if (buffer-live-p buffer)
        buffer
      (let ((new (generate-new-buffer
                  (format "*code-reader: %s*"
                          (file-name-nondirectory (code-reader-view-file view))))))
        (with-current-buffer new
          (code-reader-explanation-mode))
        (setf (code-reader-view-explanation-buffer view) new)
        new))))

;;; Layout

(defun code-reader-ui-open (view)
  "Show VIEW's two panes: source on the left, explanation on the right.
The window configuration is saved the first time the layout opens."
  (let ((source (code-reader-view-source-buffer view))
        (explanation (code-reader-ui-explanation-buffer view)))
    (unless (code-reader-ui-explanation-window view)
      (unless (code-reader-view-window-config view)
        (setf (code-reader-view-window-config view) (current-window-configuration)))
      (let ((source-window (or (code-reader-ui-source-window view) (selected-window))))
        (select-window source-window)
        (set-window-buffer source-window source)
        (delete-other-windows source-window)
        (let ((explanation-window (split-window source-window nil 'right)))
          (set-window-buffer explanation-window explanation)
          (set-window-start explanation-window
                            (with-current-buffer explanation (point-min)) t)
          (select-window source-window)))
      (when (zerop (buffer-size explanation))
        (code-reader-ui-render view)))
    ;; The question box's buffer exists from the start, but its window (the bottom
    ;; panel) is on screen only while the cursor is in it, so opening the reader
    ;; creates no panel.  The explanation takes the whole column.
    (code-reader-chat--ensure-buffer view)
    (when (code-reader-ui-explanation-window view)
      (code-reader-session-settle-explanation view))))

(defun code-reader-ui-clear-source-marks (view)
  "Remove the explained-range marks from VIEW's source buffer.
The marks belong to the explanation pane, so they go when the pane goes."
  (code-reader-highlight-clear-source (code-reader-view-source-buffer view)))

(defun code-reader-ui-hide-panel (view)
  "Hide VIEW's explanation, key guide and question box.  The explanation itself is kept."
  (code-reader-chat-hide view)
  (code-reader-ui-clear-source-marks view)
  (let ((window (code-reader-ui-explanation-window view)))
    (when window
      (condition-case nil
          (delete-window window)
        (error nil)))))

(defun code-reader-ui-close (view)
  "Close VIEW's panes and restore the window layout saved when they opened."
  (code-reader-ui-clear-source-marks view)
  (let ((config (code-reader-view-window-config view)))
    (setf (code-reader-view-window-config view) nil)
    (if config
        (set-window-configuration config)
      (code-reader-ui-hide-panel view))))

;;; Header

(defun code-reader-ui--task-label (task)
  "Return the short name used in the header for protocol TASK."
  (pcase task
    ("explain_file" "file")
    ("explain_block" "block")
    ("explain_function" "function")
    (_ "explain")))

(defun code-reader-ui--range-text (view)
  "Return the line range of VIEW's target as text, or an empty string."
  (let ((lines (code-reader-session-target-lines view)))
    (cond ((null lines) "")
          ((= (car lines) (cdr lines)) (format "line %d" (car lines)))
          (t (format "lines %d–%d" (car lines) (cdr lines))))))

(defun code-reader-ui--status-text (view)
  "Return the status words for VIEW's header."
  (pcase (code-reader-view-status view)
    ('queued "queued")
    ('running
     (format "running %ds"
             (floor (- (float-time) (or (code-reader-view-started-at view) (float-time))))))
    ('ready "ready")
    ('cached "cached")
    ('error (format "error: %s"
                    (or (plist-get (code-reader-view-error view) :code) "unknown")))
    (_ "idle")))

(defun code-reader-ui--one-line (text)
  "Return TEXT as one short line for a header line: no line breaks, and no `%' codes."
  (let ((line (replace-regexp-in-string "[ \t\n\r]+" " " (string-trim (format "%s" (or text ""))))))
    (replace-regexp-in-string "%" "%%" (truncate-string-to-width line 80 nil nil "..."))))

(defun code-reader-ui--detail-text (view)
  "Return the status of VIEW's detail explanation for the header, or nil when there is none.
A running one says how many pieces are done and for how long, so the reader can see that
it is still working.  A failed one keeps its reason until the next one starts."
  (let ((detail (code-reader-view-detail view)))
    (pcase (plist-get detail :status)
      ('running
       (let ((done (plist-get detail :done))
             (total (plist-get detail :total))
             (seconds (floor (- (float-time) (or (plist-get detail :started) (float-time))))))
         (propertize (if total
                         (format "Detail explanation running: %d of %d pieces done · %ds"
                                 (or done 0) total seconds)
                       (format "Detail explanation running: starting · %ds" seconds))
                     'face 'bold)))
      ('failed
       (propertize (format "Detail explanation failed: %s" (code-reader-ui--one-line (plist-get detail :message)))
                   'face 'error)))))

(defun code-reader-ui-header-string (view)
  "Return the one-line header for VIEW's explanation buffer."
  (let* ((root (code-reader-view-project-root view))
         (file (code-reader-view-file view))
         (name (if root (file-relative-name file root) (file-name-nondirectory file)))
         (range (code-reader-ui--range-text view))
         (parts (list (code-reader-ui--task-label (code-reader-view-task view))
                      (if (string-empty-p range) name (concat name " " range))
                      (code-reader-ui--status-text view)
                      (format "Claude: %s" (or (code-reader-view-claude-session view) "-"))
                      (format "engine: %s" (code-reader-transport-state)))))
    ;; The detail status goes first, so a narrow window cuts off the other parts, not it.
    (let ((detail (code-reader-ui--detail-text view)))
      (when detail
        (setq parts (cons detail parts))))
    (when (code-reader-view-note view)
      (setq parts (append parts (list (code-reader-view-note view)))))
    (concat " " (mapconcat (lambda (part) (if (stringp part) part (format "%s" part)))
                           parts "  ·  "))))

(defun code-reader-ui-update-header (view)
  "Refresh only the header line of VIEW's explanation buffer, when it exists."
  (let ((buffer (code-reader-view-explanation-buffer view)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (setq header-line-format (code-reader-ui-header-string view)))
      (force-window-update buffer))))

;;; Body rendering

(defun code-reader-ui--insert-code (view)
  "Insert the source text of VIEW's target, when it is known."
  (let* ((target (code-reader-view-target view))
         (start (plist-get target :start-marker))
         (end (plist-get target :end-marker)))
    (when (and (markerp start) (marker-buffer start) (markerp end) (marker-buffer end))
      (let ((text (with-current-buffer (marker-buffer start)
                    (buffer-substring-no-properties (marker-position start)
                                                    (marker-position end)))))
        (insert (propertize (format "Code (%s):\n" (code-reader-ui--range-text view))
                            'face 'bold))
        (insert (propertize text 'face 'fixed-pitch) "\n")))))

(defun code-reader-ui--insert-error (view failure)
  "Insert the FAILURE plist (:code :message :retryable) and the code of VIEW."
  (insert (propertize "Error" 'face 'error)
          (format ": %s\n" (or (plist-get failure :code) "unknown")))
  (insert (or (plist-get failure :message) "") "\n")
  (when (eq (plist-get failure :retryable) t)
    (insert "This may succeed if you press g to request it again.\n"))
  (insert "\n")
  (code-reader-ui--insert-code view))

(defun code-reader-ui--insert-body (view)
  "Insert the body of VIEW's explanation buffer for its current state.
Return non-nil when the explanation document itself was inserted."
  (let ((failure (code-reader-view-error view))
        (document (code-reader-view-document view))
        (status (code-reader-view-status view)))
    (cond
     (failure (code-reader-ui--insert-error view failure) nil)
     ((stringp document) (insert document) t)
     ((memq status '(queued running))
      (insert (propertize "Waiting for Claude…" 'face 'italic) "\n\n")
      (code-reader-ui--insert-code view)
      nil)
     (t
      (insert "No explanation yet.\n\n"
              "Explain the whole file (M-x code-reader-explain-file), select a region "
              "(M-x code-reader-explain-block) or put point in a function "
              "(M-x code-reader-explain-function).\n")
      nil))))

;;; Sections in the document

(defun code-reader-ui--index-sections (view)
  "Record each section's heading and end markers in VIEW, and mark its text with its id.
A section runs from its top-level heading to the end of its subtree, so the
questions nested under it belong to it."
  (dolist (section (code-reader-view-sections view))
    (code-reader-session--detach-markers section '(:exp-start :exp-end)))
  (with-current-buffer (code-reader-view-explanation-buffer view)
    (org-map-entries
     (lambda ()
       (let* ((id (org-entry-get nil "SECTION_ID"))
              (section (and id (cl-find id (code-reader-view-sections view)
                                        :key (lambda (candidate) (plist-get candidate :id))
                                        :test #'equal))))
         (when section
           (let ((start (point))
                 (end (save-excursion (org-end-of-subtree t t) (point))))
             (add-text-properties start end
                                  (list 'code-reader-section-id id
                                        'mouse-face 'highlight
                                        'help-echo "mouse-1 or RET: jump to the source lines"))
             (plist-put section :exp-start (copy-marker start))
             ;; Insertion type nil: a marker that advanced at the end would make this
             ;; section's range run into the next section.
             (plist-put section :exp-end (copy-marker end))))))
     "LEVEL=1")))

;;; Detail entries
;;
;; A detail entry is one line of the detail explanation: `  - N', the source line
;; number, and its explanation lines underneath.  Each is found in the text of its section, so
;; the sync can select a single source line in the explanation.

(defconst code-reader-ui--detail-item-regexp "^  - \\([0-9]+\\)\\(?: ·.*\\)?$"
  "Matches the first line of a detail entry: its source line number.
An older explanation also has the code after the number, which is ignored.")

(defun code-reader-ui--in-detail-p (position)
  "Return non-nil when POSITION is under a detail explanation heading."
  (save-excursion
    (goto-char position)
    (and (ignore-errors (org-back-to-heading t) t)
         (equal (org-entry-get nil "KIND") "detail"))))

(defun code-reader-ui--entry-end (item limit)
  "Return where the detail entry that starts at ITEM ends, without its trailing blank lines.
The entry ends before the next item, the next heading, or LIMIT.  Match data is not kept."
  (save-excursion
    (goto-char item)
    (forward-line 1)
    (goto-char (if (re-search-forward "^\\(  - [0-9]+\\(?: ·.*\\)?$\\|  Question about line\\|\\*\\)" limit t)
                   (match-beginning 0)
                 limit))
    (skip-chars-backward " \t\n" item)
    (line-beginning-position 2)))

(defun code-reader-ui-detail-entries (view section)
  "Return SECTION's detail entries that are on screen in VIEW's explanation buffer.
Each entry is a plist (:line N :start POS :end POS), where N is the source line
and POS are buffer positions, from the entry's item line to the end of its
explanation.  Entries under a folded detail explanation are not on screen, so they
are left out."
  (let ((start (plist-get section :exp-start))
        (end (plist-get section :exp-end))
        (entries nil))
    (when (and (markerp start) (marker-position start)
               (markerp end) (marker-position end))
      (with-current-buffer (code-reader-view-explanation-buffer view)
        (save-excursion
          (save-match-data
            (let ((limit (marker-position end)))
              (goto-char (marker-position start))
              (while (re-search-forward code-reader-ui--detail-item-regexp limit t)
                ;; The match data is read before any helper runs, because they search too.
                (let ((item (match-beginning 0))
                      (line (string-to-number (match-string 1))))
                  (when (and (not (invisible-p item))
                             (code-reader-ui--in-detail-p item))
                    (push (list :line line
                                :start item
                                :end (code-reader-ui--entry-end item limit))
                          entries)))))))))
    (nreverse entries)))

(defun code-reader-ui-detail-entry-for-line (view section line)
  "Return the on-screen detail entry of SECTION for source LINE, or nil."
  (and line
       (cl-find line (code-reader-ui-detail-entries view section)
                :key (lambda (entry) (plist-get entry :line)))))

(defun code-reader-ui-detail-entry-at (view section position)
  "Return the on-screen detail entry of SECTION that holds buffer POSITION, or nil."
  (cl-find-if (lambda (entry)
                (and (<= (plist-get entry :start) position)
                     (< position (plist-get entry :end))))
              (code-reader-ui-detail-entries view section)))

(defun code-reader-ui-detail-heading (view section)
  "Return where SECTION's detail explanation heading starts in VIEW's explanation buffer, or nil."
  (let ((start (plist-get section :exp-start)))
    (when (and (markerp start) (marker-position start))
      (with-current-buffer (code-reader-view-explanation-buffer view)
        (save-excursion
          (goto-char (marker-position start))
          (let ((found nil))
            (org-map-entries
             (lambda ()
               (when (and (not found) (equal (org-entry-get nil "KIND") "detail"))
                 (setq found (point))))
             "LEVEL=2" 'tree)
            found))))))

(defun code-reader-ui-show-detail (view section)
  "Open SECTION's detail explanation in VIEW's explanation pane, if it has one and it is folded.
The section is opened down to its headings, so the detail's heading is on screen, and the
detail's entries are shown.  Answers to questions stay folded.  Return non-nil when SECTION
has a detail explanation."
  (let ((detail (code-reader-ui-detail-heading view section))
        (start (plist-get section :exp-start)))
    (when detail
      (with-current-buffer (code-reader-view-explanation-buffer view)
        (unless (save-excursion (goto-char detail) (code-reader-ui--body-shown-p))
          (save-excursion
            (goto-char (marker-position start))
            (org-fold-show-entry)
            (org-fold-show-children))
          (save-excursion
            (goto-char detail)
            (org-fold-show-entry))))
      t)))

(defun code-reader-ui--heading-key ()
  "Return the key of the top-level heading at point: its section id, or its kind."
  (or (org-entry-get nil "SECTION_ID") (org-entry-get nil "KIND")))

(defun code-reader-ui--body-shown-p ()
  "Return non-nil when the text under the heading at point is visible."
  (save-excursion
    (org-end-of-meta-data t)
    (not (invisible-p (point)))))

(defun code-reader-ui--detail-key (parent-key)
  "Return the key that records whether the detail explanation under PARENT-KEY is open."
  (format "detail:%s" parent-key))

(defun code-reader-ui--parent-key ()
  "Return the heading key of the section that the heading at point belongs to."
  (save-excursion
    (org-up-heading-safe)
    (code-reader-ui--heading-key)))

(defun code-reader-ui--expanded-keys ()
  "Return the keys of the top-level headings whose text is shown, and of the open detail explanations.
A buffer with no headings yet gets the default: the summary open, the rest folded."
  (let ((keys nil)
        (headings 0))
    (when (derived-mode-p 'org-mode)
      (org-map-entries
       (lambda ()
         (cl-incf headings)
         (when (code-reader-ui--body-shown-p)
           (push (code-reader-ui--heading-key) keys)))
       "LEVEL=1")
      (org-map-entries
       (lambda ()
         (when (and (equal (org-entry-get nil "KIND") "detail") (code-reader-ui--body-shown-p))
           (push (code-reader-ui--detail-key (code-reader-ui--parent-key)) keys)))
       "LEVEL=2"))
    (if (zerop headings) '("summary") keys)))

(defun code-reader-ui--restore-folds (expanded reveal-id &optional show-details)
  "Fold every top-level heading, then open those named in EXPANDED.
An opened heading shows its text and its questions, and the answers stay folded.
REVEAL-ID, when non-nil, is opened the same way, so its newest question is in view.
A detail explanation is opened when it was open before, or always when SHOW-DETAILS."
  (save-excursion
    (org-overview)
    (org-map-entries
     (lambda ()
       (let ((key (code-reader-ui--heading-key)))
         (when (or (member key expanded) (equal key reveal-id))
           ;; The entry's text first: a heading without questions shows nothing else.
           (org-fold-show-entry)
           (org-fold-show-children))))
     "LEVEL=1")
    (org-map-entries
     (lambda ()
       (when (and (equal (org-entry-get nil "KIND") "detail")
                  (or show-details
                      (member (code-reader-ui--detail-key (code-reader-ui--parent-key)) expanded)))
         (org-fold-show-entry)))
     "LEVEL=2")))

(defun code-reader-ui--heading-of (id)
  "Return the position where section ID starts in the explanation buffer, or nil.
The ids are compared with `equal': each render makes new strings, and
`text-property-any' compares with `eq'."
  (when (stringp id)
    (let ((pos (point-min))
          (found nil))
      (while (and (not found) (< pos (point-max)))
        (if (equal (get-text-property pos 'code-reader-section-id) id)
            (setq found pos)
          (setq pos (or (next-single-property-change pos 'code-reader-section-id nil (point-max))
                        (point-max)))))
      found)))

(defun code-reader-ui--reapply-active-marks (view)
  "Mark VIEW's active detail line, or else its active section, after a redraw.
A detail line that is folded now is not on screen, so the section is marked instead
and the detail line is forgotten."
  (let* ((id (code-reader-view-active-section-id view))
         (section (and id (code-reader-session-section-by-id view id)))
         (entry (and section
                     (code-reader-ui-detail-entry-for-line
                      view section (code-reader-view-active-detail-line view))))
         (start (plist-get section :exp-start))
         (end (plist-get section :exp-end))
         (buffer (code-reader-view-explanation-buffer view)))
    (cond
     (entry
      (code-reader-highlight-set-active buffer (plist-get entry :start) (plist-get entry :end)))
     ((and (markerp start) (marker-position start)
           (markerp end) (marker-position end))
      (setf (code-reader-view-active-detail-line view) nil)
      (code-reader-highlight-set-active buffer (marker-position start) (marker-position end))))))

(defun code-reader-ui--anchor (position)
  "Return an anchor for POSITION in the explanation buffer, one that a redraw keeps.
The anchor is the id of the section at POSITION, the number of lines from that
section's heading to POSITION, and the column.  Outside every section, the lines
count from the top of the buffer."
  (let* ((id (get-text-property position 'code-reader-section-id))
         (origin (or (and id (code-reader-ui--heading-of id)) (point-min))))
    (save-excursion
      (goto-char position)
      (let ((line-start (line-beginning-position)))
        (list id (count-lines origin line-start) (- position line-start))))))

(defun code-reader-ui--last-line-end (window)
  "Return the end of the last line WINDOW shows, counted from its current start.
`pos-visible-in-window-p' reads the last redisplay, which is stale when the start
has just been set, so the screen lines are counted from the start instead."
  (with-current-buffer (window-buffer window)
    (save-excursion
      (goto-char (window-start window))
      (vertical-motion (1- (window-body-height window)) window)
      (line-end-position))))

(defun code-reader-ui--point-in-window-p (position window)
  "Return non-nil when POSITION is on screen in WINDOW, from its current start."
  (and (>= position (window-start window))
       (<= position (code-reader-ui--last-line-end window))))

(defun code-reader-ui--place-window (window start point was-in-view)
  "Show WINDOW from START, with its cursor on POINT.
WAS-IN-VIEW says whether the cursor was on screen before the redraw.  A cursor that
was on screen stays on screen: when the redraw pushed it below the window, the top
moves up to show it.  A cursor that was off screen is not brought back, because the
reader had scrolled the window away from it, so it goes to the top line.  The caller
records the new state, so the move is not taken for a scroll of the explanation."
  (set-window-start window start t)
  (cond
   ((code-reader-ui--point-in-window-p point window)
    (set-window-point window point))
   (was-in-view
    (set-window-start window
                      (with-current-buffer (window-buffer window)
                        (save-excursion
                          (goto-char point)
                          (forward-line (- (/ (window-body-height window) 2)))
                          (line-beginning-position)))
                      t)
    (set-window-point window point))
   (t
    (set-window-point window start))))

(defun code-reader-ui--anchor-position (anchor)
  "Return the position in the explanation buffer that ANCHOR names.
When that line is hidden by a fold, the section's heading is used instead."
  (let* ((id (nth 0 anchor))
         (origin (or (and id (code-reader-ui--heading-of id)) (point-min)))
         (position (save-excursion
                     (goto-char origin)
                     (forward-line (nth 1 anchor))
                     (min (+ (line-beginning-position) (nth 2 anchor))
                          (line-end-position)))))
    (if (invisible-p position) origin position)))

(defun code-reader-ui-collapse-all (view)
  "Fold every section of VIEW's explanation, so that only the section headings show.
Each section's text, questions and detail explanation fold with it.  When the point was
in text that is now folded, it moves to the heading of its section."
  (with-current-buffer (code-reader-view-explanation-buffer view)
    (org-overview)
    (when (invisible-p (point))
      (let* ((id (get-text-property (point) 'code-reader-section-id))
             (section (and id (code-reader-session-section-by-id view id)))
             (heading (plist-get section :exp-start)))
        (when (and (markerp heading) (marker-position heading))
          (goto-char (marker-position heading)))))))

(defun code-reader-ui-render (view &optional keep-top reveal-id show-details)
  "Redraw VIEW's explanation buffer from its state, and refresh its header.
With KEEP-TOP, each window keeps its place: the line at its top and the cursor
stay on the same lines, so a redraw after a new answer does not scroll the
explanation back to the start or move the cursor.  Sections keep their open or
folded state, and so do their detail explanations.  REVEAL-ID, a section id, is
opened so that its questions, including a new one, are in view.  SHOW-DETAILS
opens every detail explanation."
  (let ((buffer (code-reader-ui-explanation-buffer view)))
    (with-current-buffer buffer
      (let* ((inhibit-read-only t)
             (windows (get-buffer-window-list buffer nil t))
             ;; Each window's place is taken before the erase: the line at its top and
             ;; its cursor, as anchors that survive the redraw.
             (places (mapcar (lambda (window)
                               (list window
                                     (and keep-top (code-reader-ui--anchor (window-start window)))
                                     (and keep-top (code-reader-ui--anchor (window-point window)))
                                     (and keep-top
                                          (code-reader-ui--point-in-window-p (window-point window) window))))
                             windows))
             (expanded (code-reader-ui--expanded-keys))
             (organised nil))
        ;; The old marks would be left at the top of the buffer by the erase.
        (code-reader-highlight-clear-active buffer)
        (erase-buffer)
        (setq organised (code-reader-ui--insert-body view))
        (setq header-line-format (code-reader-ui-header-string view))
        (when organised
          (code-reader-ui--index-sections view)
          (code-reader-ui--restore-folds expanded reveal-id show-details))
        (dolist (place places)
          (let* ((window (nth 0 place))
                 (start (if (nth 1 place) (code-reader-ui--anchor-position (nth 1 place)) (point-min)))
                 (point (if (nth 2 place) (code-reader-ui--anchor-position (nth 2 place)) start)))
            (code-reader-ui--place-window window start point (nth 3 place))
            (code-reader-session-note-explanation view window)))
        (code-reader-ui--reapply-active-marks view)))))

(provide 'code-reader-ui)
;;; code-reader-ui.el ends here
