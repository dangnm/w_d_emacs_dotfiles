;;; code-reader-ui.el --- Two-pane layout and explanation buffer for Code Reader -*- lexical-binding: t; -*-

;;; Commentary:

;; Layout and rendering.  The source buffer stays in the left window and the
;; explanation buffer `*code-reader: <basename>*' opens in a right window.  The
;; window configuration from before the first open is saved, so closing restores
;; the original layout exactly.
;;
;; The explanation buffer is read-only and uses `code-reader-explanation-mode'.
;; Each section heading and body carries the text properties
;; `code-reader-section-id', `code-reader-source-start' and
;; `code-reader-source-end', which the sync and jump commands use.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
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

;;; Window lookup

(defun code-reader-ui-source-window (view)
  "Return the window showing VIEW's source buffer, or nil."
  (get-buffer-window (code-reader-view-source-buffer view)))

(defun code-reader-ui-explanation-window (view)
  "Return the window showing VIEW's explanation buffer, or nil."
  (let ((buffer (code-reader-view-explanation-buffer view)))
    (and (buffer-live-p buffer) (get-buffer-window buffer))))

;;; Explanation mode

(defvar code-reader-explanation-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "RET") #'code-reader-sync-jump-at-point)
    (define-key map [mouse-1] #'code-reader-sync-mouse-jump)
    (define-key map "g" #'code-reader-refresh)
    (define-key map "c" #'code-reader-cancel)
    (define-key map "t" #'code-reader-toggle-panel)
    (define-key map "q" #'code-reader-close)
    map)
  "Keymap for `code-reader-explanation-mode'.")

(define-derived-mode code-reader-explanation-mode special-mode "Code-Reader"
  "Major mode for the Code Reader explanation pane.
RET or mouse-1 on a section jumps to its source lines.  g refreshes the
explanation, c cancels a running request, t toggles the panel and q closes the
view.  Evil users get the same keys in motion state."
  (setq-local truncate-lines nil)
  (visual-line-mode 1))

(with-eval-after-load 'evil
  (when (fboundp 'evil-set-initial-state)
    (evil-set-initial-state 'code-reader-explanation-mode 'motion))
  (when (fboundp 'evil-define-key*)
    (evil-define-key* 'motion code-reader-explanation-mode-map
      (kbd "RET") #'code-reader-sync-jump-at-point
      "g" #'code-reader-refresh
      "c" #'code-reader-cancel
      "t" #'code-reader-toggle-panel
      "q" #'code-reader-close)))

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
        (code-reader-ui-render view)))))

(defun code-reader-ui-hide-panel (view)
  "Hide VIEW's explanation window.  The explanation itself is kept."
  (let ((window (code-reader-ui-explanation-window view)))
    (when window
      (condition-case nil
          (delete-window window)
        (error nil)))))

(defun code-reader-ui-close (view)
  "Close VIEW's panes and restore the window layout saved when they opened."
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
    ('stale (propertize "stale — press g to refresh" 'face 'code-reader-stale-face))
    ('error (format "error: %s"
                    (or (plist-get (code-reader-view-error view) :code) "unknown")))
    (_ "idle")))

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

(defun code-reader-ui--insert-section (section)
  "Insert SECTION's heading and explanation, with its source properties.
Record the explanation-buffer markers in SECTION for the sync code."
  (let* ((id (plist-get section :id))
         (start-line (plist-get section :start-line))
         (end-line (plist-get section :end-line))
         (title (plist-get section :title))
         (start (point)))
    (insert (propertize (format "Lines %d–%d%s" start-line end-line
                                (if (and (stringp title) (not (string-empty-p title)))
                                    (format " · %s" title)
                                  ""))
                        'face 'bold)
            "\n")
    (insert (or (plist-get section :explanation) "") "\n\n")
    (let ((end (point)))
      (add-text-properties start end
                           (list 'code-reader-section-id id
                                 'code-reader-source-start start-line
                                 'code-reader-source-end end-line
                                 'mouse-face 'highlight
                                 'help-echo "mouse-1 or RET: jump to the source lines"))
      (plist-put section :exp-start (copy-marker start))
      ;; Insertion type nil: the next section is inserted at this same position,
      ;; and a marker that advanced there would make this section's range run to
      ;; the end of the buffer.
      (plist-put section :exp-end (copy-marker end)))))

(defun code-reader-ui--insert-list (title items)
  "Insert a bulleted list of ITEMS under TITLE, when ITEMS is non-empty."
  (when items
    (insert (propertize title 'face 'bold) "\n")
    (dolist (item items)
      (insert "  - " (if (stringp item) item (format "%S" item)) "\n"))
    (insert "\n")))

(defun code-reader-ui--insert-warnings (warnings)
  "Insert WARNINGS (informational protocol warnings), when there are any."
  (when warnings
    (insert (propertize "Warnings" 'face 'warning) "\n")
    (dolist (warning warnings)
      (insert (format "  - [%s] %s\n"
                      (or (plist-get warning :code) "warning")
                      (or (plist-get warning :message) ""))))
    (insert "\n")))

(defun code-reader-ui--insert-result (view result)
  "Insert the explanation in RESULT (a result event) for VIEW."
  (let ((summary (plist-get result :summary)))
    (when (and (stringp summary) (not (string-empty-p summary)))
      (insert summary "\n\n")))
  (dolist (section (code-reader-view-sections view))
    (code-reader-ui--insert-section section))
  (code-reader-ui--insert-list "Dependencies" (plist-get result :dependencies))
  (code-reader-ui--insert-list "Data flow" (plist-get result :data_flow))
  (code-reader-ui--insert-list "Notes" (plist-get result :notes))
  (code-reader-ui--insert-warnings (plist-get result :warnings)))

(defun code-reader-ui--insert-body (view)
  "Insert the body of VIEW's explanation buffer for its current state."
  (let ((failure (code-reader-view-error view))
        (result (code-reader-view-last-result view))
        (status (code-reader-view-status view)))
    (cond
     (failure (code-reader-ui--insert-error view failure))
     (result (code-reader-ui--insert-result view result))
     ((memq status '(queued running))
      (insert (propertize "Waiting for Claude…" 'face 'italic) "\n\n")
      (code-reader-ui--insert-code view))
     (t
      (insert "No explanation yet.\n\n"
              "Explain the whole file (M-x code-reader-explain-file), select a region "
              "(M-x code-reader-explain-block) or put point in a function "
              "(M-x code-reader-explain-function).\n")))))

(defun code-reader-ui-render (view)
  "Redraw VIEW's explanation buffer from its state, and refresh its header."
  (let ((buffer (code-reader-ui-explanation-buffer view)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t)
            (windows (get-buffer-window-list buffer nil t)))
        (erase-buffer)
        (code-reader-ui--insert-body view)
        (setq header-line-format (code-reader-ui-header-string view))
        (dolist (window windows)
          (set-window-start window (point-min) t))))))

(provide 'code-reader-ui)
;;; code-reader-ui.el ends here
