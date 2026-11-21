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
NOTE, when non-nil, is shown in the header.  The request uses point."
  (unless buffer-file-name
    (user-error "Code Reader: this buffer is not visiting a file"))
  (code-reader-commands--check-environment)
  (let ((view (code-reader-session-view-for (current-buffer))))
    (code-reader-commands--show view)
    (code-reader-session-explain view task start-line end-line (point)
                                 :note note)))

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
need.  The engine caches the result until the file changes."
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

(defun code-reader-refresh ()
  "Request this view's explanation again, bypassing the engine cache."
  (interactive)
  (code-reader-session-refresh (code-reader-commands--existing-view)))

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
  "Ask the engine to delete its cached explanations."
  (interactive)
  (code-reader-commands--send-when-connected '(:type "clear_cache")))

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
