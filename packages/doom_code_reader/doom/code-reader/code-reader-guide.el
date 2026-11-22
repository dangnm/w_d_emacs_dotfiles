;;; code-reader-guide.el --- Key guide shown in the bottom panel -*- lexical-binding: t; -*-

;;; Commentary:

;; The key guide is a table of keys.  It is shown in the bottom panel under the
;; explanation pane.  The panel is on screen only while the cursor is in it, or
;; while the key table is up, so the explanation takes the whole column otherwise.
;; The table appears
;; when the selection moves from the source pane into the explanation pane.  It
;; goes away when the cursor moves inside the explanation pane, or when the
;; selection moves back to the source.  Selecting the panel (for example with
;; `C-w j') also clears it, so the question box is ready to type in at once.
;; Commands that leave the cursor where it was, such as mouse movement, do not
;; hide it.  Nothing here reads or writes explanation text, and no window is
;; created, deleted or resized: only the panel's buffer changes.

;;; Code:

(require 'code-reader-transport)
(require 'code-reader-session)
(require 'code-reader-chat)

(declare-function code-reader-sync-enter-explanation "code-reader-sync" (view))

(defconst code-reader-guide-buffer-name "*code-reader-guide*"
  "Buffer that holds the key guide.")

(defconst code-reader-guide-header '("Go to" . "Actions")
  "Column titles of the key guide.")

(defconst code-reader-guide-rows
  '((("RET" . "jump to the source") . ("g" . "refresh the explanation"))
    (("click" . "jump to the source") . ("r" . "refresh this section"))
    (("a" . "ask about the highlighted line or section") . ("c" . "cancel the running request"))
    (("C-w h" . "go back to the source") . ("t / q" . "toggle the pane / close the reader"))
    (("C-w j" . "go to the question box") . ("p" . "copy the cache file path"))
    (("d" . "delete the question at point") . ("D" . "explain the whole file in detail"))
    (("C" . "collapse all sections") . ("s" . "explain this section in detail")))
  "Rows of the key guide.
Each row is (LEFT . RIGHT), and each cell is (KEY . TEXT), or nil for an empty cell.")

(defvar code-reader-guide--shown nil
  "Non-nil while the key table is in the bottom panel.")

(defvar code-reader-guide--last-window nil
  "Window that was selected after the previous command.")

(defvar code-reader-guide--point nil
  "Point of the explanation pane when the key guide appeared.")

(defvar code-reader-guide--view nil
  "View whose explanation pane the key guide was shown for.")

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

(defun code-reader-guide--height ()
  "Return the number of lines the key table takes."
  (length (code-reader-guide--lines)))

(defun code-reader-guide--buffer ()
  "Return the key guide buffer, with its display settings."
  (let ((buffer (get-buffer-create code-reader-guide-buffer-name)))
    (with-current-buffer buffer
      (setq-local mode-line-format nil
                  header-line-format nil
                  truncate-lines t
                  buffer-read-only t))
    buffer))

(defun code-reader-guide--fill (text)
  "Replace the key guide buffer's text with TEXT."
  (with-current-buffer (code-reader-guide--buffer)
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert text))))

(defun code-reader-guide-hide ()
  "Clear the key table, and hide the bottom panel unless the cursor is in it."
  (setq code-reader-guide--shown nil
        code-reader-guide--point nil
        code-reader-guide--view nil)
  (code-reader-chat-release-panel))

(defun code-reader-guide--show (view)
  "Show the key table in the bottom panel, for VIEW's explanation pane."
  (let ((explanation (get-buffer-window (code-reader-view-explanation-buffer view))))
    (when (window-live-p explanation)
      (unless (code-reader-chat-panel-window)
        (code-reader-chat-show view explanation))
      (when (code-reader-chat-panel-window)
        (code-reader-guide--fill (concat (mapconcat #'identity (code-reader-guide--lines) "\n") "\n"))
        (code-reader-chat-panel-show (code-reader-guide--buffer))
        (setq code-reader-guide--shown t
              code-reader-guide--point (window-point explanation)
              code-reader-guide--view view)))))

(defun code-reader-guide--post-command ()
  "Manage the key table after each command, in the explanation pane and in the panel.
The table appears when the cursor enters the explanation pane from the source.
It stays while the cursor in the explanation pane does not move, and it is
cleared when the cursor moves there, when the selection leaves the pane, or when
the panel is selected.  Selecting the panel shows the question box."
  (code-reader--safely "key guide"
    (let ((current (selected-window))
          (previous code-reader-guide--last-window)
          (panel (code-reader-chat-panel-window)))
      (setq code-reader-guide--last-window current)
      (cond
       ;; The panel is selected: it must show the question box, not the key table.
       ((and panel (eq current panel))
        (code-reader-guide-hide)
        (code-reader-chat-panel-return-to-box))
       (t
        (let* ((buffer (window-buffer current))
               (view (and code-reader-session--views (code-reader-session-view-of buffer)))
               (in-explanation (and view (eq buffer (code-reader-view-explanation-buffer view)))))
          (cond
           ((and in-explanation
                 (window-live-p previous)
                 (eq (window-buffer previous) (code-reader-view-source-buffer view)))
            ;; The cursor goes to the highlighted section before the key table records
            ;; where it is.  A click already put the cursor where it was pressed.
            (unless (mouse-event-p last-command-event)
              (code-reader-sync-enter-explanation view))
            (code-reader-guide--show view))
           ((and in-explanation
                 code-reader-guide--shown
                 (eql (window-point current) code-reader-guide--point))
            nil)
           (t (code-reader-guide-hide)))))))))

(provide 'code-reader-guide)
;;; code-reader-guide.el ends here
