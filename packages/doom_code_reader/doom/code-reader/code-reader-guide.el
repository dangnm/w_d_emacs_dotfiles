;;; code-reader-guide.el --- Key guide under the explanation pane -*- lexical-binding: t; -*-

;;; Commentary:

;; When the selected window moves from the source pane into the explanation
;; pane, a small table of the pane's keys appears in a window just below the
;; explanation.  The table goes away when the cursor moves inside the explanation
;; pane, or when the selection moves back to the source.  Commands that leave the
;; cursor where it was, such as mouse movement, do not hide it.  Nothing here
;; reads or writes explanation text.

;;; Code:

(require 'code-reader-transport)
(require 'code-reader-session)

(defconst code-reader-guide-buffer-name "*code-reader-guide*"
  "Buffer that holds the key guide.")

(defconst code-reader-guide-header '("Go to" . "Actions")
  "Column titles of the key guide.")

(defconst code-reader-guide-rows
  '((("RET" . "jump to source") . ("g" . "refresh"))
    (("click" . "jump to source") . ("c" . "cancel"))
    (("C-w h" . "back to source") . ("t / q" . "hide pane, close")))
  "Rows of the key guide.
Each row is (LEFT . RIGHT), and each cell is (KEY . TEXT), or nil for an empty cell.")

(defvar code-reader-guide--window nil
  "Window showing the key guide, or nil when it is hidden.")

(defvar code-reader-guide--last-window nil
  "Window that was selected after the previous command.")

(defvar code-reader-guide--point nil
  "Point of the explanation pane when the key guide appeared.")

(defun code-reader-guide--cell-text (cell)
  "Return CELL as plain \"KEY: TEXT\" text, or an empty string."
  (if cell (format "%s: %s" (car cell) (cdr cell)) ""))

(defun code-reader-guide--cell (cell)
  "Return CELL as a propertized \"KEY: TEXT\" string, or an empty string."
  (if cell
      (concat (propertize (car cell) 'face 'help-key-binding) ": " (cdr cell))
    ""))

(defun code-reader-guide--pad (text width)
  "Pad TEXT with spaces to WIDTH visible characters."
  (concat text (make-string (max 0 (- width (length (substring-no-properties text)))) ?\s)))

(defun code-reader-guide--lines ()
  "Return the key guide as a list of lines: header, rule, then one line per row."
  (let* ((width (+ 2 (apply #'max (length (car code-reader-guide-header))
                            (mapcar (lambda (row)
                                      (length (code-reader-guide--cell-text (car row))))
                                    code-reader-guide-rows))))
         (header (concat " "
                         (code-reader-guide--pad (propertize (car code-reader-guide-header) 'face 'bold)
                                                 width)
                         "| " (propertize (cdr code-reader-guide-header) 'face 'bold)))
         (rule (concat " " (make-string width ?-) "+" (make-string 40 ?-))))
    (cons header
          (cons rule
                (mapcar (lambda (row)
                          (concat " "
                                  (code-reader-guide--pad (code-reader-guide--cell (car row)) width)
                                  "| " (code-reader-guide--cell (cdr row))))
                        code-reader-guide-rows)))))

(defun code-reader-guide--buffer ()
  "Return the key guide buffer, filled and read-only."
  (let ((buffer (get-buffer-create code-reader-guide-buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (mapconcat #'identity (code-reader-guide--lines) "\n") "\n"))
      (setq-local mode-line-format nil
                  header-line-format nil
                  truncate-lines t
                  buffer-read-only t))
    buffer))

(defun code-reader-guide-hide ()
  "Remove the key guide window, if it is shown."
  (when (window-live-p code-reader-guide--window)
    (ignore-errors (delete-window code-reader-guide--window)))
  (setq code-reader-guide--window nil
        code-reader-guide--point nil))

(defun code-reader-guide--show (view)
  "Show the key guide in a window directly below VIEW's explanation pane."
  (let ((explanation (get-buffer-window (code-reader-view-explanation-buffer view))))
    (code-reader-guide-hide)
    (when (window-live-p explanation)
      (let ((lines (length (code-reader-guide--lines)))
            (point (window-point explanation)))
        (setq code-reader-guide--window
              (condition-case err
                  (split-window explanation (- lines) 'below)
                (error
                 (code-reader--log "key guide: no room below the explanation pane (%s)"
                                   (error-message-string err))
                 nil)))
        (when (window-live-p code-reader-guide--window)
          (set-window-buffer code-reader-guide--window (code-reader-guide--buffer))
          (set-window-parameter code-reader-guide--window 'no-other-window t)
          (set-window-parameter code-reader-guide--window 'no-delete-other-windows t)
          (setq code-reader-guide--point point))))))

(defun code-reader-guide--post-command ()
  "Show the key guide when the cursor enters the explanation pane, and manage it after that.
The guide stays while the cursor in the explanation pane does not move.  It is
removed when the cursor moves there, or when the selection leaves the pane."
  (code-reader--safely "key guide"
    (let ((current (selected-window))
          (previous code-reader-guide--last-window))
      ;; The guide window itself can be selected; keep the state as it is then.
      (unless (eq current code-reader-guide--window)
        (setq code-reader-guide--last-window current)
        (let* ((buffer (window-buffer current))
               (view (and code-reader-session--views (code-reader-session-view-of buffer)))
               (in-explanation (and view (eq buffer (code-reader-view-explanation-buffer view)))))
          (cond
           ((and in-explanation
                 (window-live-p previous)
                 (eq (window-buffer previous) (code-reader-view-source-buffer view)))
            (code-reader-guide--show view))
           ((and in-explanation
                 (window-live-p code-reader-guide--window)
                 (eql (window-point current) code-reader-guide--point))
            nil)
           (t (code-reader-guide-hide))))))))

(provide 'code-reader-guide)
;;; code-reader-guide.el ends here
