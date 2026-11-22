;;; code-reader-session.el --- Per-view state, requests and engine events -*- lexical-binding: t; -*-

;;; Commentary:

;; A "view" ties one source file buffer to its explanation buffer and carries
;; everything about the current explanation: the pending request id, status,
;; the last result, the normalized sections (with markers in the source buffer)
;; and the markers for the explained target.
;;
;; Views live in one global registry rather than in buffer-local variables, so
;; a major-mode change in the source buffer cannot lose them.  Events from the
;; engine are matched to a view by request id; anything that no longer matches
;; the view's pending id is ignored.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'pp)
(require 'code-reader-transport)
(require 'code-reader-highlight)

;; Customization variables are defined in code-reader.el.
(defvar code-reader-explain-language)
(defvar code-reader-timeout)
(defvar code-reader-model)

(declare-function code-reader-ui-render "code-reader-ui" (view &optional keep-top reveal-id))
(declare-function code-reader-ui-update-header "code-reader-ui" (view))
(declare-function code-reader-sync-place-view "code-reader-sync" (view))

(cl-defstruct (code-reader-view (:constructor code-reader-view--create) (:copier nil))
  "State shared by a source buffer and its explanation buffer."
  source-buffer
  explanation-buffer
  file                  ; absolute file name of the source buffer
  project-root          ; directory with trailing slash
  (status 'idle)        ; idle, queued, running, ready, cached or error
  pending-id            ; request id whose events are still wanted
  task                  ; "explain_file", "explain_block" or "explain_function"
  target                ; plist with :start-marker, :end-marker and :point-marker
  phase                 ; last progress phase
  (elapsed-ms 0)
  (output-chars 0)
  started-at
  error                 ; plist with :code, :message and :retryable
  last-result           ; the last result event
  document              ; the explanation as Org text (see engine/org.py)
  explanation-key       ; cache key of that explanation, sent back with questions and refreshes
  cache-path            ; the file the explanation is stored in, or nil when it has none
  sections              ; normalized sections, see `code-reader-session--normalize-section'
  claude-session        ; "new", "resumed", "cached" or "unknown"
  note                  ; notice for the user, such as a fallback range
  window-config         ; window configuration to restore on close
  chat-buffer           ; question box under the explanation (see code-reader-chat.el)
  ;; Synchronised scrolling state (see code-reader-sync.el).
  scroll-timer
  scroll-side
  point-timer
  last-point
  sync-target           ; id of the section last placed by sync
  synced-source-start   ; window start we last set in the source pane
  synced-exp-start      ; window start we last set in the explanation pane
  synced-exp-size       ; (WIDTH HEIGHT) of the explanation pane when we last synced it
  active-section-id)

(defvar code-reader-session--views nil
  "All live views, newest first.")

(defvar code-reader-session--counter 0
  "Counter used to make request ids unique within this Emacs.")

(defvar code-reader-session--engine-info nil
  "The last `pong' event received from the engine.")


;;; Registry

(defun code-reader-session-view-of (buffer)
  "Return the view whose source or explanation buffer is BUFFER, or nil."
  (cl-find-if (lambda (view)
                (or (eq buffer (code-reader-view-source-buffer view))
                    (eq buffer (code-reader-view-explanation-buffer view))))
              code-reader-session--views))

(defun code-reader-session-project-root (file)
  "Return the project root directory for FILE, with a trailing slash.
Uses projectile when it is loaded, then the nearest \".git\" directory, and
finally the directory of FILE itself."
  (let* ((dir (file-name-directory (expand-file-name file)))
         (root (or (and (fboundp 'projectile-project-root)
                        (ignore-errors (projectile-project-root dir)))
                   (locate-dominating-file dir ".git")
                   dir)))
    (file-name-as-directory (expand-file-name root))))

(defun code-reader-session-view-for (buffer)
  "Return the view for source BUFFER, creating it on first use.
Signal a user error when BUFFER is not visiting a file."
  (or (code-reader-session-view-of buffer)
      (with-current-buffer buffer
        (unless buffer-file-name
          (user-error "Code Reader: this buffer is not visiting a file"))
        (let ((view (code-reader-view--create
                     :source-buffer buffer
                     :file (expand-file-name buffer-file-name)
                     :project-root (code-reader-session-project-root buffer-file-name))))
          (push view code-reader-session--views)
          view))))

(defun code-reader-session-dispose (view)
  "Forget VIEW: cancel its timers and request, and kill its explanation buffer."
  (dolist (timer (list (code-reader-view-scroll-timer view)
                       (code-reader-view-point-timer view)))
    (when (timerp timer)
      (cancel-timer timer)))
  (when (and (code-reader-view-pending-id view)
             (code-reader-transport-connected-p))
    (code-reader--safely "cancel on dispose"
      (code-reader--send (list :type "cancel" :id (code-reader-view-pending-id view)))))
  (setf (code-reader-view-pending-id view) nil
        (code-reader-view-scroll-timer view) nil
        (code-reader-view-point-timer view) nil)
  (code-reader-session--release-sections view)
  (code-reader-session--release-target view)
  (let ((explanation (code-reader-view-explanation-buffer view)))
    (setf (code-reader-view-explanation-buffer view) nil)
    (when (buffer-live-p explanation)
      (kill-buffer explanation)))
  (let ((chat (code-reader-view-chat-buffer view)))
    (setf (code-reader-view-chat-buffer view) nil)
    (when (buffer-live-p chat)
      (kill-buffer chat)))
  (setq code-reader-session--views (delq view code-reader-session--views)))

;;; Marker helpers

(defun code-reader-session--line-pos (line &optional end)
  "Return the position of the beginning of absolute LINE, or its end when END.
LINE is clamped to the accessible buffer.  Uses the current buffer."
  (save-restriction
    (widen)
    (save-excursion
      (goto-char (point-min))
      (forward-line (max 0 (1- line)))
      (if end (line-end-position) (line-beginning-position)))))

(defun code-reader-session--buffer-text (buffer)
  "Return the whole, widened text of BUFFER without properties."
  (with-current-buffer buffer
    (save-restriction
      (widen)
      (buffer-substring-no-properties (point-min) (point-max)))))

(defun code-reader-session--make-target (buffer start-line end-line point-pos)
  "Return a target plist with markers for the lines and point in BUFFER."
  (with-current-buffer buffer
    (list :start-marker (copy-marker (code-reader-session--line-pos start-line) nil)
          :end-marker (copy-marker (code-reader-session--line-pos end-line t) t)
          :point-marker (copy-marker point-pos nil))))

(defun code-reader-session--detach-markers (plist keys)
  "Detach each marker stored under KEYS in PLIST."
  (dolist (key keys)
    (let ((marker (plist-get plist key)))
      (when (markerp marker)
        (set-marker marker nil)))))

(defun code-reader-session--release-target (view)
  "Detach the target markers of VIEW."
  (code-reader-session--detach-markers (code-reader-view-target view)
                                       '(:start-marker :end-marker :point-marker))
  (setf (code-reader-view-target view) nil))

(defun code-reader-session--release-sections (view)
  "Detach the markers of VIEW's sections and forget them."
  (dolist (section (code-reader-view-sections view))
    (code-reader-session--detach-markers section
                                         '(:start-marker :end-marker :exp-start :exp-end)))
  (setf (code-reader-view-sections view) nil))

(defun code-reader-session-target-lines (view)
  "Return (START-LINE . END-LINE) for VIEW's target, from its markers, or nil."
  (let* ((target (code-reader-view-target view))
         (start (plist-get target :start-marker))
         (end (plist-get target :end-marker)))
    (when (and (markerp start) (marker-buffer start) (markerp end) (marker-buffer end))
      (with-current-buffer (marker-buffer start)
        (cons (line-number-at-pos (marker-position start) t)
              (line-number-at-pos (marker-position end) t))))))

;;; Request building

(declare-function code-reader-chat-handle-event "code-reader-chat" (event))

(defun code-reader-session--new-id ()
  "Return a request id unique to this Emacs process."
  (format "r-%d-%d" (emacs-pid) (cl-incf code-reader-session--counter)))

(cl-defun code-reader-session-build-request (&key id task start-line end-line point-pos use-cache)
  "Return the explain request plist for the current buffer.
Must be called in the source buffer.  TASK is a protocol task string.
START-LINE and END-LINE are absolute, 1-based lines.  POINT-POS is the buffer
position used for the point line and the symbol; it defaults to point.  When
USE-CACHE is nil the engine makes a fresh call.  Nil values are encoded as JSON
null by `code-reader-transport-encode'."
  (let* ((file (or buffer-file-name (user-error "Code Reader: this buffer is not visiting a file")))
         (pos (or point-pos (point)))
         (symbol (save-excursion (goto-char pos) (thing-at-point 'symbol t))))
    (list :type "explain"
          :id id
          :view file
          :task task
          :project_root (directory-file-name (code-reader-session-project-root file))
          :file file
          :language (symbol-name major-mode)
          :content (code-reader-session--buffer-text (current-buffer))
          :target (list :start_line start-line :end_line end-line)
          :point_line (line-number-at-pos pos t)
          :symbol symbol
          :explain_language code-reader-explain-language
          :use_cache (if use-cache t :false)
          :timeout code-reader-timeout
          :model code-reader-model)))

;;; Requests

(defun code-reader-session--fail (view id code message)
  "Fail request ID of VIEW with CODE and MESSAGE, if it is still pending."
  (when (equal id (code-reader-view-pending-id view))
    (code-reader-session--set-error
     view (list :code code :message message :retryable t))))

(cl-defun code-reader-session-explain (view task start-line end-line point-pos
                                            &key (use-cache t) note)
  "Ask the engine to explain TASK for VIEW's lines START-LINE..END-LINE.
POINT-POS is the source position used for the point line and the symbol.
A request already running for VIEW is superseded: the engine cancels it, and
its events are ignored from now on.  USE-CACHE nil forces a fresh model call.
NOTE, when non-nil, is shown in the header."
  (let ((source (code-reader-view-source-buffer view)))
    (unless (buffer-live-p source)
      (user-error "Code Reader: the source buffer is gone"))
    (let* ((id (code-reader-session--new-id))
           (superseded (memq (code-reader-view-status view) '(queued running)))
           (request (with-current-buffer source
                      (code-reader-session-build-request
                       :id id :task task :start-line start-line :end-line end-line
                       :point-pos point-pos :use-cache use-cache))))
      (code-reader-session--release-target view)
      (setf (code-reader-view-target view)
            (code-reader-session--make-target source start-line end-line point-pos)
            (code-reader-view-pending-id view) id
            (code-reader-view-task view) task
            (code-reader-view-status view) 'queued
            (code-reader-view-phase view) "queued"
            (code-reader-view-elapsed-ms view) 0
            (code-reader-view-output-chars view) 0
            (code-reader-view-started-at view) (float-time)
            (code-reader-view-error view) nil
            (code-reader-view-note view) note)
      (when superseded
        (message "Code Reader: superseded the running request"))
      (code-reader-ui-render view)
      (code-reader-transport-connect
       (lambda (error-message)
         (if error-message
             (code-reader-session--fail view id "engine_unavailable" error-message)
           (condition-case err
               (code-reader--send request)
             (error
              (code-reader-session--fail view id "engine_unavailable"
                                         (error-message-string err))))))))))

(defun code-reader-session-whole-file-lines (buffer)
  "Return (1 . LAST-LINE) for BUFFER's whole text, ignoring any narrowing."
  (with-current-buffer buffer
    (save-restriction
      (widen)
      (cons 1 (line-number-at-pos (point-max) t)))))

(defun code-reader-session-refresh (view)
  "Request VIEW's last explanation again, bypassing the engine cache.
A whole-file explanation is recomputed for the file's current length, because
the file may have grown or shrunk since the last request."
  (let* ((task (code-reader-view-task view))
         (lines (cond ((not task) nil)
                      ((equal task "explain_file")
                       (and (buffer-live-p (code-reader-view-source-buffer view))
                            (code-reader-session-whole-file-lines
                             (code-reader-view-source-buffer view))))
                      (t (code-reader-session-target-lines view))))
         (point-marker (plist-get (code-reader-view-target view) :point-marker)))
    (unless lines
      (user-error "Code Reader: nothing to refresh yet"))
    (code-reader-session-explain
     view (code-reader-view-task view) (car lines) (cdr lines)
     (or (and (markerp point-marker) (marker-position point-marker))
         (with-current-buffer (code-reader-view-source-buffer view) (point)))
     :use-cache nil :note (code-reader-view-note view))))

(defun code-reader-session-cancel (view)
  "Cancel VIEW's pending request.  Return non-nil when one was cancelled."
  (let ((id (code-reader-view-pending-id view)))
    (when id
      (setf (code-reader-view-pending-id view) nil
            (code-reader-view-status view) 'idle
            (code-reader-view-phase view) nil)
      (if (code-reader-transport-connected-p)
          (code-reader--send (list :type "cancel" :id id))
        (code-reader--log "cancel for %s dropped: engine not connected" id))
      (code-reader-ui-render view)
      t)))

;;; Sections

(defun code-reader-session--normalize-section (raw source)
  "Return a view section built from the protocol section RAW in SOURCE.
The result has `:start-line', `:end-line' and markers spanning those lines.
Return nil when RAW has no usable line range."
  (let ((start (plist-get raw :source_start))
        (end (plist-get raw :source_end)))
    (when (and (integerp start) (integerp end) (<= 1 start end))
      (with-current-buffer source
        (list :id (plist-get raw :id)
              :start-line start
              :end-line end
              :title (plist-get raw :title)
              :start-marker (copy-marker (code-reader-session--line-pos start) nil)
              :end-marker (copy-marker (code-reader-session--line-pos end t) t)
              :exp-start nil
              :exp-end nil)))))

(defun code-reader-session-section-for-target (view event)
  "Return VIEW's section whose lines are the target of EVENT, or nil."
  (let* ((target (plist-get event :target))
         (start (plist-get target :start_line))
         (end (plist-get target :end_line)))
    (cl-find-if (lambda (section)
                  (and (equal (plist-get section :start-line) start)
                       (equal (plist-get section :end-line) end)))
                (code-reader-view-sections view))))

(defun code-reader-session-apply-result (view event)
  "Take the explanation and its sections from the result EVENT into VIEW.
The engine returns the whole explanation as an Org document with every question
and refreshed section in it, so the pane can be drawn from the document alone.
The sections give the line ranges that sync and jump use."
  (let ((sections (code-reader-session--normalize-sections
                   (plist-get event :sections)
                   (code-reader-view-source-buffer view))))
    (code-reader-session--release-sections view)
    (setf (code-reader-view-sections view) sections
          (code-reader-view-document view) (plist-get event :document)
          (code-reader-view-cache-path view) (plist-get event :cache_path)
          (code-reader-view-explanation-key view)
          (or (plist-get event :explanation_key) (code-reader-view-explanation-key view)))))

(defun code-reader-session-show-cached (view event)
  "Show the saved explanation in EVENT for VIEW, without asking the engine.
The explanation covers the whole file, so the view targets the whole file, as an
explain_file request would.  No request is pending, so nothing is waiting for it."
  (let* ((source (code-reader-view-source-buffer view))
         (lines (code-reader-session-whole-file-lines source)))
    (code-reader-session--release-target view)
    (setf (code-reader-view-target view)
          (code-reader-session--make-target source (car lines) (cdr lines)
                                            (with-current-buffer source (point))))
    (setf (code-reader-view-task view) "explain_file"
          (code-reader-view-pending-id view) nil
          (code-reader-view-error view) nil
          (code-reader-view-phase view) nil
          (code-reader-view-note view) nil
          (code-reader-view-last-result view) event
          (code-reader-view-status view) 'cached
          (code-reader-view-claude-session view) "cached")
    (code-reader-session-apply-result view event)
    (code-reader-ui-render view)
    (when (fboundp 'code-reader-sync-place-view)
      (code-reader-sync-place-view view))))

(defun code-reader-session--normalize-sections (raw-sections source)
  "Return view sections for RAW-SECTIONS, in order, with markers in SOURCE."
  (delq nil (mapcar (lambda (raw) (code-reader-session--normalize-section raw source))
                    raw-sections)))

(defun code-reader-session-live-sections (view)
  "Return VIEW's sections with line numbers recomputed from their markers.
Sections whose markers were lost are left out.  Lines therefore stay right
after edits in the source buffer."
  (let ((live nil))
    (dolist (section (code-reader-view-sections view) (nreverse live))
      (let ((start (plist-get section :start-marker))
            (end (plist-get section :end-marker)))
        (when (and (markerp start) (marker-buffer start)
                   (markerp end) (marker-buffer end))
          (push (append (with-current-buffer (marker-buffer start)
                          (list :start-line (line-number-at-pos (marker-position start) t)
                                :end-line (line-number-at-pos (marker-position end) t)))
                        section)
                live))))))

(defun code-reader-session-section-by-id (view id)
  "Return VIEW's live section whose id is ID, or nil."
  (code-reader-highlight-section-by-id (code-reader-session-live-sections view) id))

;;; Explanation pane state for the scroll sync

(defun code-reader-session-window-size (window)
  "Return WINDOW's body size as (WIDTH HEIGHT)."
  (list (window-body-width window) (window-body-height window)))

(defun code-reader-session-note-explanation (view window)
  "Record WINDOW, the explanation pane, as the state the scroll sync last saw.
Call this after every window-start change the code makes.  The scroll sync
then treats a later change as a scroll only when the pane's size is unchanged."
  (setf (code-reader-view-synced-exp-start view) (window-start window)
        (code-reader-view-synced-exp-size view) (code-reader-session-window-size window)))

(defun code-reader-session-settle-explanation (view)
  "Let VIEW's explanation pane settle after the code changed its size.
Showing or hiding the key guide or the question box resizes the pane, and the
redisplay that follows can move its window start to keep point visible.  That
is a layout effect, not a scroll.  So redisplay now and record the result: the
scroll sync then sees nothing to follow."
  (let* ((buffer (code-reader-view-explanation-buffer view))
         (window (and (buffer-live-p buffer) (get-buffer-window buffer))))
    (when (window-live-p window)
      (redisplay t)
      (code-reader-session-note-explanation view window))))

;;; Staleness
;;
;; An explanation never expires on its own.  Editing the source leaves it in
;; place, and only `g' (a refresh) replaces it.

(defun code-reader-session--on-kill-buffer ()
  "Global `kill-buffer-hook': dispose a view when its source buffer dies."
  (when code-reader-session--views
    (let ((view (code-reader-session-view-of (current-buffer))))
      (when view
        (if (eq (current-buffer) (code-reader-view-source-buffer view))
            (code-reader-session-dispose view)
          (setf (code-reader-view-explanation-buffer view) nil))))))

(add-hook 'kill-buffer-hook #'code-reader-session--on-kill-buffer)

;;; Engine events

(defun code-reader-session--view-for-id (id)
  "Return the view whose pending request id is ID, or nil."
  (and id (cl-find id code-reader-session--views
                   :key #'code-reader-view-pending-id :test #'equal)))

(defun code-reader-session--set-error (view error-plist)
  "Show ERROR-PLIST (:code :message :retryable) as VIEW's failure."
  (setf (code-reader-view-pending-id view) nil
        (code-reader-view-status view) 'error
        (code-reader-view-error view) error-plist
        (code-reader-view-phase view) nil)
  (code-reader-session--release-sections view)
  (code-reader-ui-render view))

(defun code-reader-session--claude-label (event)
  "Return \"new\", \"resumed\", \"cached\" or \"unknown\" for the result EVENT.
The engine reports `session_resumed': true when the call continued an existing
Claude session.  It is null on cache hits, which is checked first."
  (cond ((eq (plist-get event :cache_hit) t) "cached")
        ((eq (plist-get event :session_resumed) t) "resumed")
        ((stringp (plist-get event :session_id)) "new")
        (t "unknown")))

(defun code-reader-session--on-progress (event)
  "Handle a `progress' EVENT for a pending request."
  (let ((view (code-reader-session--view-for-id (plist-get event :id))))
    (when view
      (let ((phase (plist-get event :phase)))
        (setf (code-reader-view-phase view) phase
              (code-reader-view-elapsed-ms view) (or (plist-get event :elapsed_ms) 0)
              (code-reader-view-output-chars view) (or (plist-get event :output_chars) 0)
              (code-reader-view-status view) (if (equal phase "queued") 'queued 'running))
        (code-reader-ui-update-header view)))))

(defun code-reader-session--on-result (event)
  "Handle a `result' EVENT: take the explanation and show it."
  (let ((view (code-reader-session--view-for-id (plist-get event :id))))
    (if (null view)
        (code-reader--log "ignored result %s: no view waits for it"
                          (plist-get event :id))
      (code-reader-session-apply-result view event)
      (setf (code-reader-view-last-result view) event
            (code-reader-view-pending-id view) nil
            (code-reader-view-error view) nil
            (code-reader-view-phase view) nil
            (code-reader-view-status view)
            (if (eq (plist-get event :cache_hit) t) 'cached 'ready)
            (code-reader-view-claude-session view)
            (code-reader-session--claude-label event))
      (code-reader-ui-render view)
      (when (fboundp 'code-reader-sync-place-view)
        (code-reader-sync-place-view view)))))

(defun code-reader-session--on-error (event)
  "Handle an `error' EVENT.  Errors without an id are only logged."
  (let ((view (code-reader-session--view-for-id (plist-get event :id)))
        (code (or (plist-get event :code) "error"))
        (message-text (or (plist-get event :message) "")))
    (if view
        (code-reader-session--set-error
         view (list :code code
                    :message message-text
                    :retryable (eq (plist-get event :retryable) t)))
      (code-reader--log "engine error %s: %s" code message-text)
      (message "Code Reader: %s" message-text))))

(defun code-reader-session--on-cancelled (event)
  "Handle a `cancelled' EVENT.  A cancel we already applied is ignored."
  (let ((view (code-reader-session--view-for-id (plist-get event :id))))
    (when view
      (setf (code-reader-view-pending-id view) nil
            (code-reader-view-status view) 'idle
            (code-reader-view-phase view) nil)
      (code-reader-ui-render view))))

(defun code-reader-session--on-pong (event)
  "Handle a `pong' EVENT: remember the engine and report Claude problems."
  (setq code-reader-session--engine-info event)
  (code-reader--log "engine %s, protocol %s" (plist-get event :engine_version)
                    (plist-get event :protocol))
  (let ((claude-error (plist-get event :claude_error)))
    (when (stringp claude-error)
      (message "Code Reader: %s" claude-error)))
  (dolist (view code-reader-session--views)
    (code-reader-ui-update-header view)))

(defun code-reader-session--on-disconnected (event)
  "Handle a `disconnected' EVENT: fail the requests that were waiting."
  (let ((reason (or (plist-get event :reason) "connection closed")))
    (dolist (view code-reader-session--views)
      (if (code-reader-view-pending-id view)
          (code-reader-session--set-error
           view (list :code "engine_disconnected"
                      :message (format "engine connection lost (%s)" reason)
                      :retryable t))
        (code-reader-ui-update-header view)))))

(defun code-reader-session--show-status (event)
  "Display a `status' EVENT in the Code Reader status buffer."
  (let ((buffer (get-buffer-create "*code-reader-status*")))
    (with-current-buffer buffer
      (unless (derived-mode-p 'special-mode)
        (special-mode))
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (pp-to-string event))))
    (display-buffer buffer)))

;;; Section refresh

(defvar code-reader-session--section-requests nil
  "Alist of (REQUEST-ID . VIEW) for section refreshes the engine has not answered yet.")

(defun code-reader-session--section-request (view section id)
  "Return the explain_section request that explains SECTION of VIEW again.
The request has a view id of its own, so it never supersedes the explanation,
and it names the explanation that it changes."
  (unless (code-reader-view-explanation-key view)
    (user-error "Code Reader: there is no explanation to change yet"))
  (let ((request (with-current-buffer (code-reader-view-source-buffer view)
                   (code-reader-session-build-request
                    :id id :task "explain_section"
                    :start-line (plist-get section :start-line)
                    :end-line (plist-get section :end-line)
                    :use-cache nil))))
    (plist-put request :explanation_key (code-reader-view-explanation-key view))
    (plist-put request :view (format "%s#refresh-%s" (code-reader-view-file view) id))))

(defun code-reader-session-refresh-section (view)
  "Explain the highlighted section of VIEW again.  The rest of the explanation stays."
  (let* ((section-id (code-reader-view-active-section-id view))
         (section (and section-id (code-reader-session-section-by-id view section-id))))
    (unless section
      (user-error "Code Reader: no section is highlighted; move the cursor in the source"))
    (let* ((id (code-reader-session--new-id))
           (request (code-reader-session--section-request view section id)))
      (push (cons id view) code-reader-session--section-requests)
      (message "Code Reader: refreshing lines %d–%d"
               (plist-get section :start-line) (plist-get section :end-line))
      (code-reader-transport-connect
       (lambda (error-message)
         (if error-message
             (code-reader-session--section-failed id error-message)
           (condition-case err
               (code-reader--send request)
             (error (code-reader-session--section-failed id (error-message-string err))))))))))

(defun code-reader-session--forget-section (id)
  "Stop waiting for the section refresh ID."
  (setq code-reader-session--section-requests
        (cl-remove id code-reader-session--section-requests :key #'car :test #'equal)))

(defun code-reader-session--section-failed (id message)
  "Report that the section refresh ID could not run, because of MESSAGE."
  (when (assoc id code-reader-session--section-requests)
    (code-reader-session--forget-section id)
    (message "Code Reader: could not refresh the section: %s" message)))

(defun code-reader-session--on-section-refreshed (view event)
  "Show the refreshed section in EVENT, which replaces its text and drops its questions.
The engine has already done that in the document it sends back, so the whole
document is taken and drawn again."
  (let ((explanation (plist-get event :explanation)))
    (if (not (stringp explanation))
        (message "Code Reader: the refreshed section had no explanation")
      (code-reader-session-apply-result view event)
      (let ((section (code-reader-session-section-for-target view event)))
        (if (null section)
            (message "Code Reader: that section is no longer in the explanation")
          (code-reader-ui-render view t)
          (message "Code Reader: refreshed lines %d–%d"
                   (plist-get section :start-line) (plist-get section :end-line)))))))

(defun code-reader-session--section-event (event)
  "Handle EVENT if it answers a section refresh.  Return non-nil when it did."
  (let* ((id (plist-get event :id))
         (entry (and (stringp id) (assoc id code-reader-session--section-requests))))
    (when entry
      (let ((view (cdr entry))
            (type (plist-get event :type)))
        (cond
         ((equal type "result")
          (code-reader-session--forget-section id)
          (code-reader-session--on-section-refreshed view event))
         ((member type '("error" "cancelled"))
          (code-reader-session--forget-section id)
          (message "Code Reader: could not refresh the section: %s"
                   (or (plist-get event :message) (plist-get event :code) type))))
        t))))

;;; Deleting a question

(defvar code-reader-session--delete-requests nil
  "Alist of (REQUEST-ID . VIEW) for question deletions the engine has not answered yet.")

(defun code-reader-session-delete-question (view section created)
  "Delete the question CREATED, under SECTION of VIEW, from the explanation and its file.
The engine does the deleting, and the view takes the explanation it sends back."
  (unless (code-reader-view-explanation-key view)
    (user-error "Code Reader: there is no explanation to change yet"))
  (let* ((id (code-reader-session--new-id))
         (request (with-current-buffer (code-reader-view-source-buffer view)
                    (code-reader-session-build-request
                     :id id :task "delete_question"
                     :start-line (plist-get section :start-line)
                     :end-line (plist-get section :end-line)
                     :use-cache nil))))
    (setq request (plist-put request :explanation_key (code-reader-view-explanation-key view)))
    (setq request (plist-put request :question_at created))
    (setq request (plist-put request :view (format "%s#delete-%s" (code-reader-view-file view) id)))
    (push (cons id view) code-reader-session--delete-requests)
    (message "Code Reader: deleting the question")
    (code-reader-transport-connect
     (lambda (error-message)
       (if error-message
           (code-reader-session--delete-failed id error-message)
         (condition-case err
             (code-reader--send request)
           (error (code-reader-session--delete-failed id (error-message-string err)))))))))

(defun code-reader-session--delete-failed (id message)
  "Report that the question deletion ID could not run, because of MESSAGE."
  (when (assoc id code-reader-session--delete-requests)
    (setq code-reader-session--delete-requests
          (cl-remove id code-reader-session--delete-requests :key #'car :test #'equal))
    (message "Code Reader: could not delete the question: %s" message)))

(defun code-reader-session--delete-event (event)
  "Handle EVENT if it answers a question deletion.  Return non-nil when it did."
  (let* ((id (plist-get event :id))
         (entry (and (stringp id) (assoc id code-reader-session--delete-requests))))
    (when entry
      (let ((view (cdr entry))
            (type (plist-get event :type)))
        (setq code-reader-session--delete-requests
              (cl-remove id code-reader-session--delete-requests :key #'car :test #'equal))
        (if (equal type "result")
            (progn
              (code-reader-session-apply-result view event)
              (code-reader-ui-render view t)
              (message "Code Reader: question deleted"))
          (message "Code Reader: could not delete the question: %s"
                   (or (plist-get event :message) (plist-get event :code) type)))
        t))))

(defun code-reader-session-handle-event (event)
  "Dispatch one engine EVENT: a question, a section refresh, a deletion, or an explanation event."
  (unless (or (code-reader-chat-handle-event event)
              (code-reader-session--section-event event)
              (code-reader-session--delete-event event))
    (code-reader-session--dispatch event)))

(defun code-reader-session--dispatch (event)
  "Dispatch an explanation EVENT by its `:type'."
  (pcase (plist-get event :type)
    ("progress" (code-reader-session--on-progress event))
    ("result" (code-reader-session--on-result event))
    ("error" (code-reader-session--on-error event))
    ("cancelled" (code-reader-session--on-cancelled event))
    ("cancel_ack"
     (unless (eq (plist-get event :active) t)
       (code-reader--log "cancel_ack: nothing running for %s"
                         (plist-get event :id))))
    ("session_reset"
     (message "Code Reader: Claude session for %s %s"
              (plist-get event :project_root)
              (if (eq (plist-get event :had_session) t) "forgotten" "was not set")))
    ("cache_cleared"
     (message "Code Reader: cleared %s cache entries" (or (plist-get event :removed) 0)))
    ("status" (code-reader-session--show-status event))
    ("pong" (code-reader-session--on-pong event))
    ("bye" (message "Code Reader: engine stopped"))
    ("disconnected" (code-reader-session--on-disconnected event))
    (_ (code-reader--log "unknown engine event: %S" (plist-get event :type)))))

(code-reader-transport-set-handler #'code-reader-session-handle-event)

(provide 'code-reader-session)
;;; code-reader-session.el ends here
