;;; code-reader-chat.el --- Ask Claude about one section -*- lexical-binding: t; -*-

;;; Commentary:

;; A question box sits under the explanation pane.  A question is about the
;; highlighted section, which is the section that holds the source point, or about
;; the highlighted line when that line has a detail entry on screen.  The engine
;; answers with a `follow_up' request, or a `follow_up_line' request for a line.  The
;; answer is kept with the section (or under the line's entry), so the engine keeps it
;; for later explanations.
;;
;; In the box, RET sends the question.  In the explanation pane, `a' moves to
;; the box.  Each question gets a view id of its own, so it never cancels the
;; explanation that is still running.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'code-reader-transport)
(require 'code-reader-session)
(require 'code-reader-ui)

(declare-function evil-set-initial-state "evil-core" (mode state))
(declare-function evil-define-key* "evil-core"
                  (state keymap key def &rest bindings))
(declare-function evil-insert-state "evil-commands" (&optional arg))

(defconst code-reader-chat-lines 9
  "Lines of the bottom panel below the explanation pane.
The panel shows the key table or the question box, one at a time, so it is as
tall as the key table.  The question box uses its header line and the first
line below it; the rest of the panel stays blank.")

(defvar code-reader-chat--panel nil
  "The bottom panel's window below the explanation pane, or nil when it is not shown.")

(defvar code-reader-chat--panel-view nil
  "The view whose question box the bottom panel shows.")

(defvar code-reader-chat--pending nil
  "Alist of (REQUEST-ID . VIEW) for questions the engine has not answered yet.")

(defvar code-reader-chat-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'code-reader-chat-send)
    map)
  "Keymap for `code-reader-chat-mode'.")

(define-derived-mode code-reader-chat-mode fundamental-mode "Code-Reader-Chat"
  "Major mode for the question box under the Code Reader explanation pane.
RET sends the question about the highlighted section."
  (setq-local truncate-lines t
              mode-line-format nil
              header-line-format nil
              display-line-numbers nil
              cursor-type t))

(with-eval-after-load 'evil
  (when (fboundp 'evil-set-initial-state)
    (evil-set-initial-state 'code-reader-chat-mode 'insert))
  (when (fboundp 'evil-define-key*)
    (evil-define-key* 'insert code-reader-chat-mode-map
      (kbd "RET") #'code-reader-chat-send)))

(defvar-local code-reader-chat--view nil
  "The view whose question box this buffer is.")

(defvar-local code-reader-chat--status nil
  "Cons of (TARGET-KEY . TEXT).  TEXT is shown only while TARGET-KEY is the target.")

;;; Buffer and window

(defun code-reader-chat--buffer-of (view)
  "Return VIEW's question box buffer, or nil when there is none."
  (let ((buffer (code-reader-view-chat-buffer view)))
    (and (buffer-live-p buffer) buffer)))

(defun code-reader-chat--ensure-buffer (view)
  "Return VIEW's question box buffer, creating it on first use."
  (or (code-reader-chat--buffer-of view)
      (let ((buffer (generate-new-buffer
                     (format "*code-reader-chat: %s*"
                             (file-name-nondirectory (code-reader-view-file view))))))
        (with-current-buffer buffer
          (code-reader-chat-mode)
          (setq code-reader-chat--view view))
        (setf (code-reader-view-chat-buffer view) buffer)
        buffer)))

;;; Bottom panel
;;
;; The panel is one window under the explanation pane.  It shows the key table
;; (the guide's buffer) while the cursor is in the explanation, and the question
;; box otherwise.  Switching what it shows never creates or deletes a window, so
;; nothing else in the layout moves.

(defun code-reader-chat-panel-window ()
  "Return the bottom panel's window, or nil when it is not shown."
  (and (window-live-p code-reader-chat--panel) code-reader-chat--panel))

(defun code-reader-chat--window (_view)
  "Return the bottom panel's window, or nil when it is not shown."
  (code-reader-chat-panel-window))

(defun code-reader-chat-panel-show (buffer)
  "Show BUFFER in the bottom panel, when the panel is shown."
  (let ((window (code-reader-chat-panel-window)))
    (when (and window (buffer-live-p buffer) (not (eq (window-buffer window) buffer)))
      (set-window-buffer window buffer))))

(defun code-reader-chat-panel-return-to-box ()
  "Make the bottom panel show the question box, with point at the end of the question.
The key table is cleared this way when the panel is selected or the cursor leaves
the explanation pane.  When the box is already shown, nothing moves, so typing
is never disturbed."
  (let* ((window (code-reader-chat-panel-window))
         (box (and code-reader-chat--panel-view
                   (code-reader-chat--buffer-of code-reader-chat--panel-view))))
    (when (and window (buffer-live-p box) (not (eq (window-buffer window) box)))
      (set-window-buffer window box)
      (set-window-point window (with-current-buffer box (point-max)))
      ;; A window's buffer does not become current by itself.  The next keys must go
      ;; to the box, so make it current when the panel is the selected window.
      (when (eq window (selected-window))
        (set-buffer box)))))

(defun code-reader-chat-show (view explanation-window)
  "Show VIEW's bottom panel below EXPLANATION-WINDOW, with the question box in it.
The panel is created once.  When it is already shown, it is switched to the
question box.  Does nothing when EXPLANATION-WINDOW is not live."
  (when (window-live-p explanation-window)
    (let ((buffer (code-reader-chat--ensure-buffer view)))
      (setq code-reader-chat--panel-view view)
      (if (code-reader-chat-panel-window)
          (code-reader-chat-panel-show buffer)
        (let ((window (condition-case nil
                          (split-window explanation-window (- code-reader-chat-lines) 'below)
                        (error nil))))
          (when (window-live-p window)
            (setq code-reader-chat--panel window)
            (set-window-buffer window buffer)
            (set-window-parameter window 'no-delete-other-windows t)
            (code-reader-session-settle-explanation view))))
      (code-reader-chat-refresh view))))

(defun code-reader-chat-hide (view)
  "Remove the bottom panel, if it is shown."
  (let ((window (code-reader-chat-panel-window)))
    (when window
      (ignore-errors (delete-window window))
      (setq code-reader-chat--panel nil)
      (code-reader-session-settle-explanation view))))

(defun code-reader-chat-release-panel ()
  "Hide the bottom panel unless the cursor is in it.
The panel is on screen only while the cursor is there, so that the explanation
takes the whole column the rest of the time.  The question box's text is kept."
  (let ((window (code-reader-chat-panel-window)))
    (when (and window (not (eq window (selected-window))))
      (ignore-errors (delete-window window))
      (setq code-reader-chat--panel nil)
      (when code-reader-chat--panel-view
        (code-reader-session-settle-explanation code-reader-chat--panel-view)))))

(defun code-reader-chat-focus ()
  "Move to the question box under the explanation pane, ready to type."
  (interactive)
  (let* ((view (or (code-reader-session-view-of (current-buffer))
                   (user-error "Code Reader: no explanation here")))
         (explanation (code-reader-ui-explanation-window view)))
    (code-reader-chat-show view explanation)
    (let ((window (code-reader-chat-panel-window)))
      (unless window
        (user-error "Code Reader: the question box could not be shown"))
      (code-reader-chat-panel-return-to-box)
      (select-window window)
      (goto-char (point-max))
      (when (fboundp 'evil-insert-state)
        (evil-insert-state)))))

;;; Drawing

(defun code-reader-chat--target (view)
  "Return the section the question box is about: VIEW's highlighted section, or nil."
  (let ((id (code-reader-view-active-section-id view)))
    (and id (code-reader-session-section-by-id view id))))

(defun code-reader-chat--line-target (view)
  "Return the source line the question box is about, or nil for the whole section.
The line is the one highlighted in VIEW, when its detail entry is on screen.  Without a
detail entry, the question is about the section, as before."
  (let ((section (code-reader-chat--target view))
        (line (code-reader-view-active-detail-line view)))
    (and section line
         (code-reader-ui-detail-entry-for-line view section line)
         line)))

(defun code-reader-chat--target-key (view)
  "Return the question box's target as a key: (START END LINE), or nil when there is no section."
  (let ((section (code-reader-chat--target view)))
    (and section (list (plist-get section :start-line) (plist-get section :end-line)
                       (code-reader-chat--line-target view)))))

(defun code-reader-chat--range-text (start end)
  "Return START..END as text for a header."
  (if (= start end)
      (format "line %d" start)
    (format "lines %d–%d" start end)))

(defun code-reader-chat--header (view)
  "Return the header line of VIEW's question box."
  (let* ((section (code-reader-chat--target view))
         (key (code-reader-chat--target-key view))
         (line (code-reader-chat--line-target view))
         (status (and code-reader-chat--status
                      (equal (car code-reader-chat--status) key)
                      (cdr code-reader-chat--status)))
         (where (if section
                    (let* ((title (plist-get section :title))
                           (start (plist-get section :start-line))
                           (end (plist-get section :end-line))
                           (range (code-reader-chat--range-text start end)))
                      (format "About %s%s"
                              (cond ((null line) range)
                                    ((= start end) (format "line %d" line))
                                    (t (format "line %d of %s" line range)))
                              (if (and (stringp title) (not (string-empty-p title)))
                                  (format " · %s" title)
                                "")))
                  "Move the cursor into a section in the source to choose it")))
    (concat " " (propertize where 'face 'bold)
            (if status (concat "  —  " status) "")
            (if section "   RET sends" ""))))

(defun code-reader-chat--input-text ()
  "Return the question typed so far: the whole text of the current question box.
The header is the window's header line, not buffer text, so the box holds only
what the reader typed, wherever point is."
  (buffer-substring-no-properties (point-min) (point-max)))

(defun code-reader-chat-refresh (view)
  "Redraw VIEW's question box header.  The question typed so far is left alone."
  (let ((buffer (code-reader-chat--buffer-of view)))
    (when buffer
      (with-current-buffer buffer
        (setq header-line-format (code-reader-chat--header view))))))

(defun code-reader-chat--set-status (view text)
  "Show TEXT in VIEW's question box, for the section that is the target now."
  (let ((buffer (code-reader-chat--buffer-of view)))
    (when buffer
      (with-current-buffer buffer
        (setq code-reader-chat--status (cons (code-reader-chat--target-key view) text)))
      (code-reader-chat-refresh view))))

;;; Asking

(defun code-reader-chat--request (view section question id &optional line)
  "Return the request that asks QUESTION about SECTION of VIEW, or about LINE of it when given.
A question about a line is a follow_up_line request, and the answer goes under that line's
detail entry.  The request has a view id of its own, so it never supersedes the explanation.
It names the explanation that the answer is added to."
  (unless (code-reader-view-explanation-key view)
    (user-error "Code Reader: there is no explanation to ask about yet"))
  (let ((request (with-current-buffer (code-reader-view-source-buffer view)
                   (code-reader-session-build-request
                    :id id :task (if line "follow_up_line" "follow_up")
                    :start-line (plist-get section :start-line)
                    :end-line (plist-get section :end-line)))))
    (setq request (plist-put request :view (format "%s#chat-%s" (code-reader-view-file view) id)))
    (setq request (plist-put request :explanation_key (code-reader-view-explanation-key view)))
    (setq request (plist-put request :question question))
    (if line (plist-put request :line line) request)))

(defun code-reader-chat-send ()
  "Send the question typed in the box, about the highlighted line, or else the highlighted section."
  (interactive)
  (let* ((view (or code-reader-chat--view (user-error "Code Reader: this is not a question box")))
         (question (string-trim (code-reader-chat--input-text)))
         (section (code-reader-chat--target view)))
    (when (string-empty-p question)
      (user-error "Code Reader: type a question first"))
    (unless section
      (user-error "Code Reader: no section is highlighted; move the cursor in the source"))
    (let* ((id (code-reader-session--new-id))
           (request (code-reader-chat--request view section question id (code-reader-chat--line-target view))))
      (push (cons id view) code-reader-chat--pending)
      (erase-buffer)
      (code-reader-chat--set-status view "asking Claude…")
      (code-reader-transport-connect
       (lambda (error-message)
         (if error-message
             (code-reader-chat--failed id error-message)
           (condition-case err
               (code-reader--send request)
             (error (code-reader-chat--failed id (error-message-string err))))))))))

(defun code-reader-chat--forget (id)
  "Stop waiting for the question ID."
  (setq code-reader-chat--pending
        (cl-remove id code-reader-chat--pending :key #'car :test #'equal)))

(defun code-reader-chat--failed (id message)
  "Report that the question ID could not be sent, because of MESSAGE."
  (let ((entry (assoc id code-reader-chat--pending)))
    (when entry
      (code-reader-chat--forget id)
      (code-reader-chat--set-status (cdr entry) (format "not sent: %s" message)))))

;;; Answers

(defun code-reader-chat--on-answer (view event)
  "Show the answer in EVENT as a question nested under its section, in VIEW.
The engine returns the explanation document with the answer in it.  The section
is opened, so that the new question is in view, and the rest keeps its state."
  (code-reader-session-apply-result view event)
  (let ((section (code-reader-session-section-for-target view event)))
    (code-reader-ui-render view t (and section (plist-get section :id)))
    (code-reader-chat--set-status
     view (if section
              "answered"
            "answered, but that section is no longer in the explanation"))))

(defun code-reader-chat-handle-event (event)
  "Handle ENGINE EVENT when it belongs to a question from a question box.
Return non-nil when the event was for such a question, so the caller skips it."
  (let* ((id (plist-get event :id))
         (entry (and (stringp id) (assoc id code-reader-chat--pending))))
    (when entry
      (let ((view (cdr entry))
            (type (plist-get event :type)))
        (cond
         ((equal type "result")
          (code-reader-chat--forget id)
          (code-reader-chat--on-answer view event))
         ((equal type "error")
          (code-reader-chat--forget id)
          (code-reader-chat--set-status
           view (format "error: %s" (or (plist-get event :message) (plist-get event :code) "unknown"))))
         ((equal type "cancelled")
          (code-reader-chat--forget id)
          (code-reader-chat--set-status view "cancelled")))
        t))))

(provide 'code-reader-chat)
;;; code-reader-chat.el ends here
