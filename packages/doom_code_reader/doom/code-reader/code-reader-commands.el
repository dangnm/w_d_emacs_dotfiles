;;; code-reader-commands.el --- Interactive commands for Code Reader -*- lexical-binding: t; -*-

;;; Commentary:

;; The interactive commands.  Autoloads for them are declared in code-reader.el,
;; so that loading the feature the first time pulls in the whole package.
;; Key bindings are left to the user's configuration.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'code-reader-transport)
(require 'code-reader-session)
(require 'code-reader-ui)
(require 'code-reader-sync)
(require 'code-reader-cache)

;; Customization variables are defined in code-reader.el.
(defvar code-reader-python-command)
(defvar code-reader-explain-language)

(defconst code-reader-commands-function-max-lines 400
  "Functions longer than this are not explained whole.")

(defconst code-reader-commands-window-radius 30
  "Lines before and after point used when no suitable function is found.")

;;; Helpers

(defun code-reader-commands--show (view)
  "Make sure VIEW's two panes are visible and the scroll sync is installed."
  (code-reader-sync-setup)
  (code-reader-ui-open view)
  (code-reader-commands--install-pane-hooks view))

(defun code-reader-commands--install-pane-hooks (view)
  "Run the cursor sync and the key guide after each command, in VIEW's two panes.
The hooks are buffer-local, not global: a buffer whose local `post-command-hook'
does not include `t' never runs the global value, so a global hook can be
skipped in the source buffer, which is where point moves."
  (dolist (buffer (list (code-reader-view-source-buffer view)
                        (code-reader-view-explanation-buffer view)))
    (with-current-buffer buffer
      (add-hook 'post-command-hook #'code-reader-sync--post-command nil t)
      ;; Each function checks which pane it runs in, so both panes get both.
      (add-hook 'post-command-hook #'code-reader-sync--explanation-post-command nil t)
      (add-hook 'post-command-hook #'code-reader-guide--post-command nil t)))
  ;; The bottom panel shows the key table or the question box.  Selecting the panel
  ;; runs its hook in whichever of the two buffers the panel showed, so both need it.
  (dolist (buffer (list (code-reader-chat--ensure-buffer view) (code-reader-guide--buffer)))
    (with-current-buffer buffer
      (add-hook 'post-command-hook #'code-reader-guide--post-command nil t))))

(defun code-reader-commands--existing-view ()
  "Return the view for the current buffer, which must already exist."
  (or (code-reader-session-view-of (current-buffer))
      (user-error "Code Reader: no explanation here; run code-reader-open first")))

(defun code-reader-commands--view-here ()
  "Return the view for the current buffer, creating one for a file buffer."
  (or (code-reader-session-view-of (current-buffer))
      (if buffer-file-name
          (code-reader-session-view-for (current-buffer))
        (user-error "Code Reader: this buffer is not visiting a file"))))

(defun code-reader-commands--check-environment ()
  "Signal a readable user error when the Python or claude command is missing."
  (unless (executable-find code-reader-python-command)
    (user-error "Code Reader: cannot find %s; set `code-reader-python-command'"
                code-reader-python-command))
  (let ((claude (code-reader-transport-claude-bin)))
    (unless (or (file-executable-p claude) (executable-find claude))
      (user-error "Code Reader: cannot find the claude CLI; %s"
                  "set `code-reader-claude-command'"))))

(defun code-reader-commands--send-when-connected (object)
  "Send OBJECT to the engine, connecting first when needed."
  (code-reader-transport-connect
   (lambda (error-message)
     (if error-message
         (message "Code Reader: %s" error-message)
       (condition-case err
           (code-reader--send object)
         (error (message "Code Reader: %s" (error-message-string err))))))))

(defun code-reader-commands--explain (task start-line end-line note)
  "Request an explanation of TASK for START-LINE..END-LINE in this file buffer.
NOTE, when non-nil, is shown in the header.  The request uses point.
A saved whole-file explanation is shown from its file, and the engine is not
started.  The engine runs for a new explanation (g), and for questions."
  (unless buffer-file-name
    (user-error "Code Reader: this buffer is not visiting a file"))
  (let* ((view (code-reader-session-view-for (current-buffer)))
         (saved (and (equal task "explain_file") (code-reader-cache-find view))))
    (unless saved
      (code-reader-commands--check-environment))
    (code-reader-commands--show view)
    (if saved
        (code-reader-session-show-cached view (code-reader-cache-event saved))
      (code-reader-session-explain view task start-line end-line (point)
                                   :note note))))

(defun code-reader-commands--defun-lines ()
  "Return (START-LINE . END-LINE) of the function containing point, or nil.
Uses `beginning-of-defun' and `end-of-defun' inside `save-excursion'.
Moving to the end of the line first makes point count as inside its own
defun, even on the opening line, where `beginning-of-defun' would otherwise
go to the previous defun."
  (save-excursion
    (let ((origin (point)))
      (condition-case nil
          (progn
            (end-of-line)
            (when (beginning-of-defun)
              (let ((beg (point)))
                (end-of-defun)
                (when (and (bolp) (> (point) beg))
                  (backward-char))
                (let ((end (point)))
                  (when (and (<= beg origin) (<= origin end))
                    (cons (line-number-at-pos beg t)
                          (line-number-at-pos end t)))))))
        (error nil)))))

;;; Public commands

;;;###autoload
(defun code-reader-open ()
  "Open the two-pane Code Reader view for the current file.
The first time a file is opened, its whole content is explained.  Later
opens keep the explanation already on screen; press `g' to regenerate it."
  (interactive)
  (let ((view (code-reader-commands--view-here)))
    (code-reader-commands--show view)
    (unless (or (code-reader-view-task view)
                (memq (code-reader-view-status view) '(queued running)))
      (code-reader-explain-file))))

;;;###autoload
(defun code-reader-explain-file ()
  "Explain the whole current file with Claude, in the explanation pane.
The explanation covers every line, so scroll the source to find the part you
need.  A saved explanation of the file is shown without starting the engine; press
`g' to explain the file again."
  (interactive)
  (let ((lines (code-reader-session-whole-file-lines (current-buffer))))
    (code-reader-commands--explain "explain_file" (car lines) (cdr lines) nil)))

;;;###autoload
(defun code-reader-explain-block ()
  "Explain the active region with Claude.
The region is taken by lines.  When it ends at column 0, that line is left out."
  (interactive)
  (unless (use-region-p)
    (user-error "Code Reader: select a region first"))
  (let* ((beg (region-beginning))
         (end (region-end))
         (start-line (line-number-at-pos beg t))
         (end-line (line-number-at-pos end t)))
    (when (and (> end-line start-line)
               (save-excursion (goto-char end) (bolp)))
      (setq end-line (1- end-line)))
    (code-reader-commands--explain "explain_block" start-line end-line nil)))

;;;###autoload
(defun code-reader-explain-function ()
  "Explain the function around point with Claude.
When point is not inside a function of at most
`code-reader-commands-function-max-lines' lines, explain the window of
`code-reader-commands-window-radius' lines before and after point instead, and
say so in the header."
  (interactive)
  (let* ((bounds (code-reader-commands--defun-lines))
         (length (and bounds (1+ (- (cdr bounds) (car bounds))))))
    (if (and length (<= length code-reader-commands-function-max-lines))
        (code-reader-commands--explain "explain_function"
                                       (car bounds) (cdr bounds) nil)
      (let* ((line (line-number-at-pos nil t))
             (total (line-number-at-pos (point-max) t))
             (start (max 1 (- line code-reader-commands-window-radius)))
             (end (min total (+ line code-reader-commands-window-radius))))
        (code-reader-commands--explain
         "explain_function" start end
         (format "no enclosing function of %d lines or fewer; explaining %d–%d"
                 code-reader-commands-function-max-lines start end))))))

(defun code-reader-cancel ()
  "Cancel the explanation request running for this view."
  (interactive)
  (unless (code-reader-session-cancel (code-reader-commands--existing-view))
    (message "Code Reader: nothing is running")))

(defun code-reader-commands--refresh-prompt (view)
  "Return the yes-or-no question that asks before VIEW's explanation is replaced."
  (let ((path (code-reader-view-cache-path view)))
    (format "Regenerate the explanation of %s? %s is replaced, and Claude is asked again. "
            (file-name-nondirectory (code-reader-view-file view))
            (if path (format "The saved file %s" path) "The explanation"))))

(defun code-reader-refresh ()
  "Explain this view's file again, bypassing the saved explanation and the engine cache.
The saved file is replaced, so this asks first.  Questions asked about lines that
the file still has are kept."
  (interactive)
  (let ((view (code-reader-commands--existing-view)))
    (unless (code-reader-view-task view)
      (user-error "Code Reader: nothing to refresh yet"))
    (if (y-or-n-p (code-reader-commands--refresh-prompt view))
        (code-reader-session-refresh view)
      (message "Code Reader: explanation kept"))))

(defun code-reader-refresh-section ()
  "Explain the highlighted section again, and leave the rest of the explanation as it is."
  (interactive)
  (code-reader-session-refresh-section (code-reader-commands--existing-view)))

(defun code-reader-collapse-all ()
  "Collapse every section of the explanation in this pane, so that only the headings show.
Nothing is saved, and the source is not changed.  Moving the cursor in the source into a
section that has a detail explanation opens that detail again."
  (interactive)
  (code-reader-ui-collapse-all (code-reader-commands--existing-view)))

(defun code-reader-explain-detail ()
  "Explain the whole file in detail, after asking yes or no.
Every lines group gets a \"Detail explanation\" subsection, with one entry per line
of code, read from the top down.  Claude is asked for a few dozen lines at a time,
and several calls run together, so this takes several minutes.  The details already
shown are replaced; the questions and the rest of the explanation are kept.  `c'
cancels it."
  (interactive)
  (let ((view (code-reader-commands--existing-view)))
    ;; The checks come first, so that a question is never asked about something that cannot run.
    (code-reader-session-check-detail-start view)
    (if (y-or-n-p (concat "Explain every line of the file in detail? Claude is asked in pieces "
                          "of a few dozen lines, so this takes several minutes. "
                          "The details already shown are replaced. "))
        (code-reader-session-explain-detail view)
      (message "Code Reader: detail explanation not started"))))

(defun code-reader-explain-section-detail ()
  "Explain the highlighted section in detail, line by line.
Only that section's lines are asked about, and the rest of the explanation is kept.
It starts without a question, because it is only one section's worth of calls.  `c'
cancels it."
  (interactive)
  (let* ((view (code-reader-commands--existing-view))
         (section (code-reader-session-highlighted-section view)))
    (code-reader-session-explain-detail view section)))

(defun code-reader-copy-cache-path ()
  "Show the cache file of the explanation on screen, and copy its path.
The path goes to the kill ring and to the system clipboard, so it can be pasted
elsewhere.  The file is the explanation as an Org document."
  (interactive)
  (let* ((view (code-reader-commands--existing-view))
         (path (code-reader-view-cache-path view)))
    (unless path
      (user-error "Code Reader: this explanation has no cache file"))
    (kill-new path)
    (code-reader-commands--copy-to-clipboard path)
    (message "Code Reader: %s (copied)" path)))

(defun code-reader-commands--copy-to-clipboard (text)
  "Put TEXT on the system clipboard: through the window system, or with pbcopy."
  (cond ((display-graphic-p) (gui-set-selection 'CLIPBOARD text))
        ((executable-find "pbcopy")
         (with-temp-buffer
           (insert text)
           (call-process-region (point-min) (point-max) "pbcopy")))))

(defun code-reader-commands--question-at-point ()
  "Return a plist (:created :text :section) for the question at point, or nil.
Point is on a question when the nearest heading is a \"** Question:\" heading of the
explanation.  CREATED is its CREATED time, which identifies it to the engine."
  (save-excursion
    (condition-case nil
        (progn
          (org-back-to-heading t)
          (when (equal (org-entry-get nil "KIND") "question")
            (let ((created (org-entry-get nil "CREATED"))
                  (heading (org-get-heading t t t t)))
              (org-up-heading-safe)
              (when created
                (list :created created
                      :text (string-trim (replace-regexp-in-string "\\`Question: *" "" heading))
                      :section (org-entry-get nil "SECTION_ID"))))))
      (error nil))))

(defun code-reader-delete-question ()
  "Delete the question at point from the explanation and its saved file, after asking.
Point must be on a \"** Question:\" heading, or in its text.  It cannot be undone."
  (interactive)
  (let* ((view (code-reader-commands--existing-view))
         (question (code-reader-commands--question-at-point)))
    (unless question
      (user-error "Code Reader: point is not on a question"))
    (let ((section (code-reader-session-section-by-id view (plist-get question :section))))
      (unless section
        (user-error "Code Reader: that question's section is no longer in the explanation"))
      (if (y-or-n-p (format "Delete the question \"%s\"? It is removed from the saved file, and cannot be undone. "
                            (truncate-string-to-width (plist-get question :text) 60 nil nil "...")))
          (code-reader-session-delete-question view section (plist-get question :created))
        (message "Code Reader: question kept")))))

(defun code-reader-toggle-panel ()
  "Show or hide the explanation pane.  The explanation is kept while hidden."
  (interactive)
  (let ((view (code-reader-commands--view-here)))
    (if (code-reader-ui-explanation-window view)
        (code-reader-ui-hide-panel view)
      (code-reader-commands--show view))))

(defun code-reader-close ()
  "Close the explanation pane and restore the layout from before it opened."
  (interactive)
  (code-reader-ui-close (code-reader-commands--existing-view)))

(defun code-reader-clear-cache ()
  "Delete every saved explanation, in every project.  This asks first, because it cannot be undone."
  (interactive)
  (if (y-or-n-p "Delete ALL saved explanations, in every project? This cannot be undone. ")
      (code-reader-commands--send-when-connected '(:type "clear_cache"))
    (message "Code Reader: nothing deleted")))

(defun code-reader-reset-session ()
  "Forget the Claude session the engine keeps for the current project."
  (interactive)
  (let ((root (cond ((code-reader-session-view-of (current-buffer))
                     (code-reader-view-project-root
                      (code-reader-session-view-of (current-buffer))))
                    (buffer-file-name
                     (code-reader-session-project-root buffer-file-name))
                    (t (file-name-as-directory
                        (read-directory-name "Project root: " nil nil t))))))
    (code-reader-commands--send-when-connected
     (list :type "reset_session" :project_root (directory-file-name root)))))

(defun code-reader-show-status ()
  "Ask the engine for its status and show it in a buffer."
  (interactive)
  (code-reader-commands--send-when-connected '(:type "status")))

(defun code-reader-set-language (language)
  "Set the language that explanations are written in to LANGUAGE.
Applies to the next explanation requested."
  (interactive
   (list (completing-read (format "Explain in (now %s): " code-reader-explain-language)
                          '("Vietnamese" "English")
                          nil nil nil nil code-reader-explain-language)))
  (let ((chosen (string-trim language)))
    (when (string-empty-p chosen)
      (user-error "Code Reader: the language cannot be empty"))
    (setq code-reader-explain-language chosen)
    (message "Code Reader: explanations will be written in %s" chosen)))

(defun code-reader-shutdown-engine ()
  "Stop the engine: send `shutdown' if connected, else stop our own process."
  (interactive)
  (message "Code Reader: %s" (code-reader-transport-shutdown)))

(provide 'code-reader-commands)
;;; code-reader-commands.el ends here
