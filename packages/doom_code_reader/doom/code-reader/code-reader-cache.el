;;; code-reader-cache.el --- Show a saved explanation without the engine -*- lexical-binding: t; -*-

;;; Commentary:

;; The engine stores each explanation as an Org file, in a folder for the project and
;; the source file (see engine/cache.py).  Opening a file reads that file here, so the
;; engine is not started when the explanation is already saved.  The engine runs only
;; when the reader asks for something that needs Claude: a new explanation (g), a
;; question, or a section refresh.
;;
;; The folder and file names are computed the way the engine computes them.  If they
;; ever differ, nothing is found, and the engine runs as it did before.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'code-reader-transport)
(require 'code-reader-session)

;; Customization variables are defined in code-reader.el.
(defvar code-reader-explain-language)
(defvar code-reader-model)

(defun code-reader-cache--sanitize (text)
  "Replace each run of characters that names cannot hold with \"-\", as the engine does."
  (replace-regexp-in-string "[^A-Za-z0-9._-]+" "-" text))

(defun code-reader-cache-project-folder (root)
  "Return the folder name that the engine gives the project at ROOT.
This is `project_folder' in engine/cache.py: the directory name, and a short hash of
the root path, so that two projects with the same name do not share a folder."
  (let* ((root (directory-file-name root))
         (name (string-trim (code-reader-cache--sanitize (file-name-nondirectory root))
                            "[-.]+" "[-.]+")))
    (format "%s-%s"
            (if (string-empty-p name) "project" name)
            (substring (secure-hash 'sha256 root) 0 6))))

(defun code-reader-cache--language-part (language)
  "Return LANGUAGE as the engine writes it in a file name."
  (let ((safe (string-trim (code-reader-cache--sanitize language) "-+" "-+")))
    (if (string-empty-p safe) "text" safe)))

(defun code-reader-cache--folder (view)
  "Return the folder that the engine uses for VIEW's file."
  (let* ((root (directory-file-name (file-truename (code-reader-view-project-root view))))
         (relative (file-relative-name (file-truename (code-reader-view-file view))
                                       (file-name-as-directory root))))
    (expand-file-name relative
                      (expand-file-name (code-reader-cache-project-folder root)
                                        (expand-file-name "cache/"
                                                          (code-reader-transport-state-directory))))))

(defun code-reader-cache--read (path)
  "Return the text of PATH, or nil when it cannot be read."
  (condition-case nil
      (with-temp-buffer
        (insert-file-contents path)
        (buffer-string))
    (file-error nil)))

(defun code-reader-cache--header (text keyword)
  "Return the value of the header line \"#+KEYWORD:\" in TEXT, or nil."
  (when (string-match (format "^#\\+%s: *\\(.*?\\) *$" keyword) text)
    (match-string 1 text)))

(defun code-reader-cache--mtime (path)
  "Return the modification time of PATH."
  (file-attribute-modification-time (file-attributes path)))

(defun code-reader-cache-find (view)
  "Return the saved whole-file explanation of VIEW's file, or nil when there is none.
The result is a plist with :text, :key, :path and :mtime.  Among the files for this
file in the reader's language, the newest one made with the reader's model is taken.
The model is read from the file's header, where the engine wrote it.  Nothing here
checks the prompts: a saved explanation stays until the reader presses g."
  (let* ((folder (code-reader-cache--folder view))
         (pattern (format "\\`whole-file-%s-[0-9a-f]\\{8\\}\\.org\\'"
                          (regexp-quote (code-reader-cache--language-part code-reader-explain-language))))
         (model (or code-reader-model "default"))
         (best nil))
    (when (file-directory-p folder)
      (dolist (path (directory-files folder t pattern t))
        (let* ((text (code-reader-cache--read path))
               (key (and text (code-reader-cache--header text "KEY")))
               (mtime (code-reader-cache--mtime path)))
          (when (and key
                     (string-match-p "\\`[0-9a-f]\\{64\\}\\'" key)
                     ;; A file without a MODEL header was written before the header existed,
                     ;; with the default model.
                     (equal (or (code-reader-cache--header text "MODEL") "default") model)
                     (or (null best) (time-less-p (plist-get best :mtime) mtime)))
            (setq best (list :text text :key key :path path :mtime mtime))))))
    best))

(defun code-reader-cache-sections (text)
  "Return the sections of the explanation document TEXT as protocol-style plists.
Each has :id, :source_start, :source_end and :title, taken from the section headings
and their :SECTION_ID: property lines."
  (with-temp-buffer
    (insert text)
    (goto-char (point-min))
    (let ((sections nil))
      (while (re-search-forward "^\\* Lines \\([0-9]+\\)–\\([0-9]+\\)\\(?: · \\(.*\\)\\)?$" nil t)
        (let ((start (string-to-number (match-string 1)))
              (end (string-to-number (match-string 2)))
              (title (or (match-string 3) "")))
          (save-excursion
            (when (re-search-forward "^  :SECTION_ID: \\(.+\\)$" nil t)
              (push (list :id (string-trim (match-string 1))
                          :source_start start :source_end end :title title)
                    sections)))))
      (nreverse sections))))

(defun code-reader-cache-event (saved)
  "Return the result event that shows SAVED, a plist from `code-reader-cache-find'."
  (let ((text (plist-get saved :text)))
    (list :type "result"
          :cache_hit t
          :explanation_key (plist-get saved :key)
          :cache_path (plist-get saved :path)
          :document text
          :sections (code-reader-cache-sections text))))

(provide 'code-reader-cache)
;;; code-reader-cache.el ends here
