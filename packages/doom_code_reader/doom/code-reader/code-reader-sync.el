;;; code-reader-sync.el --- Synchronised scrolling and jumps for Code Reader -*- lexical-binding: t; -*-

;;; Commentary:

;; Keeps the source pane and the explanation pane in step.  Everything is
;; driven by line numbers and section source ranges, never by scroll-bar
;; percentages, and nothing calls the model.
;;
;;   A. Source pane scrolled: the section at the vertical middle of the source
;;      pane is placed at the top of the explanation pane and highlighted.
;;   B. Explanation pane scrolled: the section at the top of the explanation
;;      pane is found from its text properties; the source pane is scrolled so
;;      that the section starts at its top, and its source lines are highlighted.
;;      Scroll-driven sync never moves the source point.
;;   C. Source point moved: after idle, the section containing point is
;;      highlighted in the explanation pane.  When the cursor enters a different
;;      section, that section is placed at the top of the explanation pane, even
;;      if it is already on screen.  A scroll that the cursor caused is left to C.
;;   D. Explanation RET or mouse-1: the source point moves to the section, the
;;      source pane recentres, and the source range is highlighted.
;;
;; Recursion is prevented by three checks.  `code-reader-sync--syncing' is bound
;; while a window is moved by code.  A pane whose window start equals the value
;; the code last set is treated as our own movement.  And a sync is skipped when
;; its target section equals the last one placed.  Scroll events are debounced
;; with idle timers.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'code-reader-transport)
(require 'code-reader-session)
(require 'code-reader-highlight)
(require 'code-reader-ui)

(declare-function code-reader-chat-refresh "code-reader-chat" (view))

(defvar code-reader-sync--syncing nil
  "Non-nil while Code Reader moves a window itself; scroll events are ignored.")

(defconst code-reader-sync-idle-delay 0.1
  "Idle seconds to wait after a scroll or cursor move before syncing.")

;;; Hook installation

(defun code-reader-sync-setup ()
  "Install the global scroll hook that drives synchronisation.
The cursor hook is buffer-local; see `code-reader-commands--install-pane-hooks'.
Safe to call more than once."
  (add-hook 'window-scroll-functions #'code-reader-sync--on-window-scroll))

(defun code-reader-sync--schedule (view side)
  "Debounce a sync for VIEW after pane SIDE (`source' or `explanation') moved."
  (setf (code-reader-view-scroll-side view) side)
  (unless (timerp (code-reader-view-scroll-timer view))
    (setf (code-reader-view-scroll-timer view)
          (run-with-idle-timer code-reader-sync-idle-delay nil
                               #'code-reader-sync--run-scroll view))))

(defun code-reader-sync--on-window-scroll (window _start)
  "Global `window-scroll-functions' hook: schedule a sync for a view pane."
  (code-reader--safely "scroll sync"
    (when (and code-reader-session--views (not code-reader-sync--syncing))
      (let* ((buffer (window-buffer window))
             (view (code-reader-session-view-of buffer)))
        (when view
          (cond ((eq buffer (code-reader-view-source-buffer view))
                 ;; A scroll that moving the cursor caused is left to the cursor sync (C),
                 ;; which takes the section the cursor is in.  Its timer is pending now.
                 (unless (timerp (code-reader-view-point-timer view))
                   (code-reader-sync--schedule view 'source)))
                ((eq buffer (code-reader-view-explanation-buffer view))
                 (code-reader-sync--schedule view 'explanation))))))))

(defun code-reader-sync--run-scroll (view)
  "Idle callback that performs the debounced scroll sync for VIEW."
  (setf (code-reader-view-scroll-timer view) nil)
  (code-reader--safely "scroll sync"
    (pcase (code-reader-view-scroll-side view)
      ('source (code-reader-sync-source-scrolled view))
      ('explanation (code-reader-sync-explanation-scrolled view)))))

(defun code-reader-sync--post-command ()
  "Post-command hook in a source pane: schedule a cursor sync after point moved."
  (code-reader--safely "cursor sync"
    (when code-reader-session--views
      (let ((view (code-reader-session-view-of (current-buffer))))
        (when (and view
                   (eq (current-buffer) (code-reader-view-source-buffer view))
                   (not (eql (point) (code-reader-view-last-point view))))
          (setf (code-reader-view-last-point view) (point))
          (when (timerp (code-reader-view-point-timer view))
            (cancel-timer (code-reader-view-point-timer view)))
          (setf (code-reader-view-point-timer view)
                (run-with-idle-timer code-reader-sync-idle-delay nil
                                     #'code-reader-sync--run-point view)))))))

(defun code-reader-sync--run-point (view)
  "Idle callback for C: highlight the section that holds the source point."
  (setf (code-reader-view-point-timer view) nil)
  (code-reader--safely "cursor sync"
    (let ((source (code-reader-view-source-buffer view)))
      (when (buffer-live-p source)
        (let* ((line (with-current-buffer source (line-number-at-pos (point) t)))
               (section (code-reader-highlight-section-at-line
                         (code-reader-session-live-sections view) line)))
          (when (and section
                     (not (equal (plist-get section :id)
                                 (code-reader-view-active-section-id view))))
            (code-reader-sync--highlight-active view section)
            (code-reader-sync--follow-in-explanation view section)))))))

(defun code-reader-sync--follow-in-explanation (view section)
  "Place SECTION at the top of VIEW's explanation pane, because the cursor entered it.
This is done even when SECTION is already on screen, so that the pane moves line by
line with the cursor, as it does when the source is paged."
  (let ((window (code-reader-ui-explanation-window view)))
    (when (window-live-p window)
      (setf (code-reader-view-sync-target view) (plist-get section :id))
      (code-reader-sync--show-in-explanation view section window))))

(defun code-reader-sync-place-view (view)
  "Place VIEW's explanation after a new explanation arrived.
The pane shows the highlighted section.  With no highlighted section, it is
placed by the source's middle line, as for any scroll of the source."
  (let* ((id (code-reader-view-active-section-id view))
         (section (and id (code-reader-session-section-by-id view id)))
         (window (code-reader-ui-explanation-window view)))
    (if (and section (window-live-p window))
        (progn
          (setf (code-reader-view-sync-target view) id)
          (code-reader-sync--show-in-explanation view section window))
      (code-reader-sync-refresh-view view))))

(defun code-reader-sync-enter-explanation (view)
  "Put the explanation cursor on the highlighted section when the reader enters the pane.
The highlight follows the source cursor, so entering the pane lands on the lines
the reader is working on.  The pane is scrolled only when that section is out of
view.  Does nothing when no section is highlighted."
  (let* ((id (code-reader-view-active-section-id view))
         (section (and id (code-reader-session-section-by-id view id)))
         (marker (plist-get section :exp-start))
         (window (code-reader-ui-explanation-window view)))
    (when (and (window-live-p window) (markerp marker) (marker-position marker))
      (let ((heading (marker-position marker)))
        (unless (code-reader-ui--point-in-window-p heading window)
          (code-reader-sync--show-in-explanation view section window))
        (set-window-point window heading)
        (with-current-buffer (window-buffer window)
          (goto-char heading))))))

;;; Helpers

(defun code-reader-sync--middle-line (window)
  "Return the absolute line at the vertical middle of WINDOW's source view.
The buffer point of WINDOW's buffer is preserved."
  (with-current-buffer (window-buffer window)
    (save-excursion
      (goto-char (window-start window))
      (forward-line (/ (window-body-height window) 2))
      (line-number-at-pos (point) t))))

(defun code-reader-sync--section-id-at (buffer position)
  "Return the section id at POSITION in the explanation BUFFER, or nil.
Text outside every section, such as the summary, has no id, so the explanation
pane does not drive the source pane while it shows that text."
  (with-current-buffer buffer
    (get-text-property position 'code-reader-section-id)))

(defun code-reader-sync--highlight-active (view section)
  "Highlight SECTION (with explanation markers) as VIEW's active section."
  (let ((start (plist-get section :exp-start))
        (end (plist-get section :exp-end)))
    (when (and (markerp start) (marker-position start)
               (markerp end) (marker-position end))
      (code-reader-highlight-set-active (code-reader-view-explanation-buffer view)
                                        (marker-position start) (marker-position end))
      (setf (code-reader-view-active-section-id view) (plist-get section :id))
      ;; The question box is about the highlighted section, so it follows the highlight.
      (code-reader-chat-refresh view))))

(defun code-reader-sync--set-top (window position &optional move-point)
  "Scroll WINDOW so POSITION is its first line; return the new window start.
With MOVE-POINT, also move WINDOW's point to POSITION when the point would
otherwise be off screen.  The source pane never passes MOVE-POINT."
  (let ((code-reader-sync--syncing t))
    (set-window-start window position)
    (when (and move-point
               (not (pos-visible-in-window-p (window-point window) window)))
      (set-window-point window position))
    (window-start window)))

(defun code-reader-sync--show-in-explanation (view section window)
  "Scroll explanation WINDOW so that SECTION's heading is at the top."
  (let ((marker (plist-get section :exp-start)))
    (when (and (markerp marker) (marker-position marker))
      (code-reader-sync--set-top window (marker-position marker) t)
      (code-reader-session-note-explanation view window))))

(defun code-reader-sync--show-in-source (view section window)
  "Scroll source WINDOW so SECTION starts at its top and highlight its lines.
The source point is not moved."
  (let ((start (plist-get section :start-marker))
        (end (plist-get section :end-marker)))
    (when (and (markerp start) (marker-position start)
               (markerp end) (marker-position end))
      (setf (code-reader-view-synced-source-start view)
            (code-reader-sync--set-top window (marker-position start)))
      (code-reader-highlight-set-source (window-buffer window)
                                        (marker-position start) (marker-position end)))))

;;; A and B: scroll-driven sync

(defun code-reader-sync-refresh-view (view)
  "Place VIEW's explanation at the section matching the source pane.
Used after a new result.  Forces the placement even if the source has not moved."
  (setf (code-reader-view-sync-target view) nil
        (code-reader-view-synced-source-start view) nil)
  (code-reader-sync-source-scrolled view))

(defun code-reader-sync-source-scrolled (view)
  "A: put the section at the middle of VIEW's source pane atop the explanation."
  (let ((source-window (code-reader-ui-source-window view))
        (explanation-window (code-reader-ui-explanation-window view)))
    (when (and source-window explanation-window
               (not (eql (window-start source-window)
                         (code-reader-view-synced-source-start view))))
      (let* ((line (code-reader-sync--middle-line source-window))
             (section (code-reader-highlight-nearest-section
                       (code-reader-session-live-sections view) line)))
        (when section
          (let ((id (plist-get section :id)))
            (code-reader-sync--highlight-active view section)
            (unless (equal id (code-reader-view-sync-target view))
              (setf (code-reader-view-sync-target view) id)
              (code-reader-sync--show-in-explanation view section explanation-window))))))))

(defun code-reader-sync-explanation-scrolled (view)
  "B: scroll VIEW's source pane to the section atop the explanation pane.
A change of the explanation pane's size is a layout effect, not a scroll.  It
only records the pane's state; see `code-reader-session-settle-explanation'."
  (let ((source-window (code-reader-ui-source-window view))
        (explanation-window (code-reader-ui-explanation-window view)))
    (when (and source-window explanation-window)
      (cond
       ((not (equal (code-reader-session-window-size explanation-window)
                    (code-reader-view-synced-exp-size view)))
        (code-reader-session-note-explanation view explanation-window))
       ((not (eql (window-start explanation-window)
                  (code-reader-view-synced-exp-start view)))
        (code-reader-session-note-explanation view explanation-window)
        (let* ((top (window-start explanation-window))
               (id (code-reader-sync--section-id-at
                    (code-reader-view-explanation-buffer view) top))
               (section (and id (code-reader-session-section-by-id view id))))
          ;; The explanation highlight stays on the section that holds the source
          ;; point (C).  Only the source pane and its range move here, so the
          ;; highlight never disagrees with where the cursor is.
          (when section
            (unless (equal id (code-reader-view-sync-target view))
              (setf (code-reader-view-sync-target view) id)
              (code-reader-sync--show-in-source view section source-window)))))))))

;;; D: click or RET in the explanation pane

(defun code-reader-sync-jump (view id)
  "D: move the source point to section ID of VIEW and highlight its lines.
The layout is kept, and focus stays in the explanation pane."
  (let* ((section (or (code-reader-session-section-by-id view id)
                      (user-error "Code Reader: that section is gone")))
         (source (code-reader-view-source-buffer view))
         (start (marker-position (plist-get section :start-marker)))
         (end (marker-position (plist-get section :end-marker)))
         (window (get-buffer-window source)))
    (with-current-buffer source
      (goto-char start))
    (when window
      ;; The source window is usually not selected here, because the jump starts in
      ;; the explanation pane, and a window keeps its own point.  Set it first:
      ;; selecting the window for `recenter' would otherwise put the buffer's point
      ;; back where the window had it.
      (set-window-point window start)
      (with-selected-window window
        (recenter))
      (setf (code-reader-view-synced-source-start view) (window-start window)))
    (code-reader-highlight-set-source source start end)
    (code-reader-sync--highlight-active view section)
    (setf (code-reader-view-sync-target view) id)
    (message "Code Reader: %s lines %d–%d · %s"
             (file-name-nondirectory (code-reader-view-file view))
             (with-current-buffer source (line-number-at-pos start t))
             (with-current-buffer source (line-number-at-pos end t))
             (or (plist-get section :title) ""))))

(defun code-reader-sync-jump-at-point ()
  "Jump to the source lines of the explanation section at point."
  (interactive)
  (let* ((view (or (code-reader-session-view-of (current-buffer))
                   (user-error "Code Reader: not an explanation buffer")))
         (id (get-text-property (point) 'code-reader-section-id)))
    (if id
        (code-reader-sync-jump view id)
      (message "Code Reader: point is not on a section"))))

(defun code-reader-sync-mouse-jump (event)
  "Mouse-1 handler: move point to the click, then jump to its section."
  (interactive "e")
  (mouse-set-point event)
  (code-reader-sync-jump-at-point))

(provide 'code-reader-sync)
;;; code-reader-sync.el ends here
