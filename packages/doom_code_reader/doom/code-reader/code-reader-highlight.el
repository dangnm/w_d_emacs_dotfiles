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
  '((t :inherit font-lock-keyword-face :weight bold))
  "Colour of the fringe bar that marks the explanation section for the code under point."
  :group 'code-reader)

(defface code-reader-source-range-face
  '((t :inherit font-lock-builtin-face :weight bold))
  "Colour of the fringe bar that marks the source lines of the section that was jumped to."
  :group 'code-reader)


(defvar-local code-reader-highlight--active-marks nil
  "Fringe-bar overlays marking the active section in the explanation buffer.")

(defvar-local code-reader-highlight--source-marks nil
  "Fringe-bar overlays marking the explained source range in the source buffer.")

;;; Marks
;;
;; A mark is a column of bars in the left fringe, one bar per line.  The text
;; keeps its own colours, unlike a background highlight, which is hard to read.
;; Each mark is an empty overlay at the start of a line whose `before-string' is
;; drawn in the fringe.

(defun code-reader-highlight--mark-lines (buffer var start end face)
  "Replace the marks held in VAR (buffer-local in BUFFER) with one bar per line in START..END."
  (when (and (buffer-live-p buffer) (integerp start) (integerp end))
    (with-current-buffer buffer
      (mapc #'delete-overlay (symbol-value var))
      (set var nil)
      (save-excursion
        (let ((stop (max start end))
              (marks nil))
          (goto-char (min start end))
          (while (< (point) stop)
            ;; A line hidden by an Org fold gets no bar. Its section's heading stays
            ;; visible and keeps the bar.
            (unless (invisible-p (point))
              (let ((overlay (make-overlay (point) (point) buffer)))
                (overlay-put overlay 'before-string
                             (propertize " " 'display (list 'left-fringe 'filled-rectangle face)))
                (overlay-put overlay 'code-reader t)
                (push overlay marks)))
            (forward-line 1))
          (set var (nreverse marks)))))))

(defun code-reader-highlight--clear (var buffer)
  "Delete the marks held in VAR in BUFFER, if any."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (mapc #'delete-overlay (symbol-value var))
      (set var nil))))

(defun code-reader-highlight-set-active (buffer start end)
  "Mark the lines START..END in the explanation BUFFER as the active section."
  (code-reader-highlight--mark-lines buffer 'code-reader-highlight--active-marks start end
                                     'code-reader-active-section-face))

(defun code-reader-highlight-clear-active (buffer)
  "Remove the active-section marks from the explanation BUFFER."
  (code-reader-highlight--clear 'code-reader-highlight--active-marks buffer))

(defun code-reader-highlight-set-source (buffer start end)
  "Mark the lines START..END in the source BUFFER as the explained range.
Callers pass whole-line bounds (beginning of the first line, end of the last)."
  (code-reader-highlight--mark-lines buffer 'code-reader-highlight--source-marks start end
                                     'code-reader-source-range-face))

(defun code-reader-highlight-clear-source (buffer)
  "Remove the explained-range marks from the source BUFFER."
  (code-reader-highlight--clear 'code-reader-highlight--source-marks buffer))

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
