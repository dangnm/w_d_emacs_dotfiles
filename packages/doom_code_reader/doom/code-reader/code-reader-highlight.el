;;; code-reader-highlight.el --- Faces, overlays and section lookup for Code Reader -*- lexical-binding: t; -*-

;;; Commentary:

;; Faces and overlay helpers for the explanation and source panes, plus pure
;; functions that map a source line to an explanation section.
;;
;; The pure functions take a list of section plists, each with `:id',
;; `:start-line' and `:end-line' (1-based, inclusive), and need no buffers or
;; windows, so the unit tests call them directly.  Sections may overlap and may
;; lie outside the requested target.

;;; Code:

(require 'cl-lib)

(defface code-reader-active-section-face
  '((t :inherit highlight :extend t))
  "Face marking the explanation section that matches the code being viewed."
  :group 'code-reader)

(defface code-reader-source-range-face
  '((t :inherit region :extend t))
  "Face marking the source lines explained by the section that was jumped to."
  :group 'code-reader)

(defface code-reader-stale-face
  '((t :inherit warning :weight bold))
  "Face for the stale-explanation notice in the explanation header."
  :group 'code-reader)

(defvar-local code-reader-highlight--active-overlay nil
  "Overlay marking the active section in the explanation buffer.")

(defvar-local code-reader-highlight--source-overlay nil
  "Overlay marking the explained source range in the source buffer.")

;;; Overlays

(defun code-reader-highlight--move (var buffer start end face)
  "Replace the overlay in VAR (buffer-local in BUFFER) by START..END in FACE."
  (when (and (buffer-live-p buffer) (integerp start) (integerp end))
    (with-current-buffer buffer
      (when (overlayp (symbol-value var))
        (delete-overlay (symbol-value var)))
      (let ((overlay (make-overlay (min start end) (max start end) buffer)))
        (overlay-put overlay 'face face)
        (overlay-put overlay 'code-reader t)
        (set var overlay)))))

(defun code-reader-highlight--clear (var buffer)
  "Delete the overlay held in VAR in BUFFER, if any."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (overlayp (symbol-value var))
        (delete-overlay (symbol-value var)))
      (set var nil))))

(defun code-reader-highlight-set-active (buffer start end)
  "Highlight START..END in the explanation BUFFER as the active section."
  (code-reader-highlight--move 'code-reader-highlight--active-overlay
                               buffer start end
                               'code-reader-active-section-face))

(defun code-reader-highlight-clear-active (buffer)
  "Remove the active-section highlight from the explanation BUFFER."
  (code-reader-highlight--clear 'code-reader-highlight--active-overlay buffer))

(defun code-reader-highlight-set-source (buffer start end)
  "Highlight START..END in the source BUFFER as the explained range.
Callers pass whole-line bounds (beginning of the first line, end of the last)."
  (code-reader-highlight--move 'code-reader-highlight--source-overlay
                               buffer start end 'code-reader-source-range-face))

(defun code-reader-highlight-clear-source (buffer)
  "Remove the explained-range highlight from the source BUFFER."
  (code-reader-highlight--clear 'code-reader-highlight--source-overlay buffer))

;;; Pure section lookup

(defun code-reader-highlight--span (section)
  "Return the number of lines SECTION covers, minus one."
  (- (plist-get section :end-line) (plist-get section :start-line)))

(defun code-reader-highlight-section-at-line (sections line)
  "Return the section in SECTIONS that contains LINE, or nil.
When several sections contain LINE, pick the one with the smallest span
\(end minus start); break ties by the lower start line."
  (let ((best nil))
    (dolist (section sections best)
      (let ((start (plist-get section :start-line))
            (end (plist-get section :end-line)))
        (when (and (<= start line) (<= line end))
          (when (or (null best)
                    (< (code-reader-highlight--span section)
                       (code-reader-highlight--span best))
                    (and (= (code-reader-highlight--span section)
                            (code-reader-highlight--span best))
                         (< start (plist-get best :start-line))))
            (setq best section)))))))

(defun code-reader-highlight-nearest-section (sections line)
  "Return the section containing LINE, or else the nearest one in SECTIONS.
Distance is measured from LINE to the closest edge of a section; ties go to
the section with the lower start line.  Returns nil when SECTIONS is empty."
  (or (code-reader-highlight-section-at-line sections line)
      (let ((best nil)
            (best-distance nil))
        (dolist (section sections best)
          (let* ((start (plist-get section :start-line))
                 (end (plist-get section :end-line))
                 (distance (cond ((< line start) (- start line))
                                 ((> line end) (- line end))
                                 (t 0))))
            (when (or (null best-distance)
                      (< distance best-distance)
                      (and (= distance best-distance)
                           (< start (plist-get best :start-line))))
              (setq best section
                    best-distance distance)))))))

(defun code-reader-highlight-section-by-id (sections id)
  "Return the section in SECTIONS whose `:id' equals ID, or nil."
  (cl-find id sections
           :key (lambda (section) (plist-get section :id))
           :test #'equal))

(provide 'code-reader-highlight)
;;; code-reader-highlight.el ends here
