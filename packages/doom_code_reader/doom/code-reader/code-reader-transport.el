;;; code-reader-transport.el --- Engine connection and framing for Code Reader -*- lexical-binding: t; -*-

;;; Commentary:

;; Talks to the Python engine over a UNIX stream socket, using the
;; newline-delimited JSON protocol described in PROTOCOL.md.
;;
;; Nothing here waits for the engine.  `code-reader-transport-connect' starts a
;; non-blocking connection attempt.  If the socket does not accept it, the engine
;; is started with `make-process' and attempts are retried from a timer, up to
;; `code-reader-transport-max-attempts' times.  Incoming lines are decoded one by
;; one and passed to the handler installed with
;; `code-reader-transport-set-handler'.
;;
;; Bytes are read with `:coding binary' and decoded per line, so a multibyte
;; character split across two process chunks is never mangled.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)

;; Customization variables are defined in code-reader.el, which loads this file.
(defvar code-reader-package-root)
(defvar code-reader-python-command)
(defvar code-reader-claude-command)
(defvar code-reader-claude-env-remove)
(defvar code-reader-state-directory)
(defvar code-reader-socket-file)

(defconst code-reader-log-buffer-name "*code-reader-log*"
  "Buffer that collects Code Reader diagnostics.")

(defconst code-reader-engine-buffer-name "*code-reader-engine*"
  "Buffer that receives the engine's standard error.")

(defconst code-reader-transport-max-attempts 50
  "Connection attempts made after starting the engine (50 x 100 ms).")

(defconst code-reader-transport-retry-interval 0.1
  "Seconds between connection attempts.")

(defconst code-reader-transport-max-socket-bytes 103
  "Longest accepted socket path; UNIX socket paths are limited to ~104 bytes.")

;;; Logging and error containment

(defun code-reader--log (format-string &rest args)
  "Append a timestamped line made from FORMAT-STRING and ARGS to the log."
  (with-current-buffer (get-buffer-create code-reader-log-buffer-name)
    (let ((inhibit-read-only t))
      (goto-char (point-max))
      (insert (format-time-string "[%H:%M:%S] ")
              (apply #'format format-string args)
              "\n"))))

(defmacro code-reader--safely (context &rest body)
  "Evaluate BODY.  On error, log it with CONTEXT and return nil instead.
Use this around hook functions, process filters and sentinels so that a bug
in Code Reader cannot break the user's Emacs."
  (declare (indent 1) (debug t))
  `(condition-case err
       (progn ,@body)
     (error
      (code-reader--log "%s failed: %s" ,context (error-message-string err))
      nil)))

;;; Framing and encoding (pure)

(defun code-reader-transport-decode-chunk (pending chunk)
  "Split PENDING followed by CHUNK into complete lines.
Return a cons (LINES . REMAINDER): LINES is the list of complete lines, without
their newline, and REMAINDER is the trailing partial line to keep for later."
  (let ((data (concat pending chunk))
        (pos 0)
        (lines nil))
    (while (string-match "\n" data pos)
      (push (substring data pos (match-beginning 0)) lines)
      (setq pos (match-end 0)))
    (cons (nreverse lines) (substring data pos))))

(defun code-reader-transport-parse-line (line)
  "Decode one protocol LINE into a plist, or return nil.
Blank lines return nil.  Malformed JSON is logged and also returns nil."
  (let ((text (string-trim line)))
    (unless (string-empty-p text)
      (let ((decoded (if (multibyte-string-p text)
                         text
                       (decode-coding-string text 'utf-8))))
        (condition-case err
            (let ((message (json-parse-string decoded
                                              :object-type 'plist
                                              :array-type 'list
                                              :null-object nil
                                              :false-object :false)))
              (if (and (consp message) (keywordp (car message)))
                  message
                (code-reader--log "engine sent a non-object line: %.200s"
                                  decoded)
                nil))
          (error
           (code-reader--log "engine sent invalid JSON (%s): %.200s"
                             (error-message-string err) decoded)
           nil))))))

(defun code-reader--json-plist (plist)
  "Return PLIST with nil values replaced by :null, recursing into sub-plists.
`json-serialize' would encode nil as an empty object, so outgoing values must
use :null explicitly."
  (let ((out nil))
    (while plist
      (let ((key (pop plist))
            (value (pop plist)))
        (push key out)
        (push (cond ((null value) :null)
                    ((and (consp value) (keywordp (car value)))
                     (code-reader--json-plist value))
                    (t value))
              out)))
    (nreverse out)))

(defun code-reader-transport-encode (object)
  "Return OBJECT, a keyword plist, as one JSON line without a newline."
  (json-serialize (code-reader--json-plist object)
                  :null-object :null
                  :false-object :false))

;;; Paths and commands

(defun code-reader-transport-state-directory ()
  "Return `code-reader-state-directory' as an absolute directory name."
  (file-name-as-directory (expand-file-name code-reader-state-directory)))

(defun code-reader-transport-socket-path ()
  "Return the absolute socket path; signal a user error if it is too long."
  (let ((path (expand-file-name
               (or code-reader-socket-file
                   (expand-file-name "engine.sock"
                                     (code-reader-transport-state-directory))))))
    (when (> (string-bytes path) code-reader-transport-max-socket-bytes)
      (user-error "Code Reader: socket path is too long (%d bytes); %s"
                  (string-bytes path)
                  "set `code-reader-socket-file' to a shorter path"))
    path))

(defun code-reader-transport-claude-bin ()
  "Return the claude CLI to pass to the engine.
Uses `code-reader-claude-command' when set, else ~/.local/bin/claude when it is
executable, else the first `claude' on `exec-path'.  Falls back to the bare name
so that the engine reports `claude_not_found' over the protocol."
  (or code-reader-claude-command
      (let ((local (expand-file-name "~/.local/bin/claude")))
        (and (file-executable-p local) local))
      (executable-find "claude")
      "claude"))

(defun code-reader-transport-engine-command (socket)
  "Return the command line that starts the engine listening on SOCKET."
  (append (list code-reader-python-command
                "-m" "engine"
                "--socket" socket
                "--state-dir" (directory-file-name (code-reader-transport-state-directory))
                "--claude-bin" (code-reader-transport-claude-bin))
          (when code-reader-effort (list "--effort" code-reader-effort))
          (apply #'append
                 (mapcar (lambda (var) (list "--drop-env" var))
                         code-reader-claude-env-remove))))

;;; Connection state

(defvar code-reader-transport--conn nil
  "Network process for the engine socket, while connecting or open.")

(defvar code-reader-transport--open nil
  "Non-nil once the current socket has reached the open state.")

(defvar code-reader-transport--input ""
  "Unterminated bytes received from the engine so far.")

(defvar code-reader-transport--waiters nil
  "Callbacks waiting for the current connection attempt, newest first.")

(defvar code-reader-transport--timer nil
  "Repeating timer that drives connection attempts; non-nil while connecting.")

(defvar code-reader-transport--attempts 0
  "Number of retries made during the current connection attempt.")

(defvar code-reader-transport--engine nil
  "Engine process started by this Emacs, or nil.")

(defvar code-reader-transport--engine-started nil
  "Non-nil when the current connection attempt has started the engine.")

(defvar code-reader-transport--handler nil
  "Function called with each decoded engine message (a plist).")

(defun code-reader-transport-set-handler (function)
  "Install FUNCTION as the handler for decoded engine messages."
  (setq code-reader-transport--handler function))

(defun code-reader-transport-connected-p ()
  "Return non-nil when the engine socket is open."
  (and code-reader-transport--conn
       (eq (process-status code-reader-transport--conn) 'open)))

(defun code-reader-transport--connecting-p ()
  "Return non-nil while a connection attempt is still in progress."
  (and code-reader-transport--conn
       (eq (process-status code-reader-transport--conn) 'connect)))

(defun code-reader-transport--engine-live-p ()
  "Return non-nil when the engine process started by this Emacs is running."
  (and code-reader-transport--engine
       (process-live-p code-reader-transport--engine)))

(defun code-reader-transport-state ()
  "Return the engine state: `connected', `starting' or `offline'."
  (cond ((code-reader-transport-connected-p) 'connected)
        ((or code-reader-transport--timer (code-reader-transport--engine-live-p)) 'starting)
        (t 'offline)))

;;; Sending

(defun code-reader--send (object)
  "Send OBJECT, a plist, to the engine as one JSON line.
Signal an error when there is no open connection."
  (unless (code-reader-transport-connected-p)
    (error "Code Reader: not connected to the engine"))
  (process-send-string code-reader-transport--conn
                       (concat (encode-coding-string
                                (code-reader-transport-encode object) 'utf-8)
                               "\n")))

;;; Receiving

(defun code-reader-transport--handle (message)
  "Pass MESSAGE, a plist, to the installed handler, containing any error."
  (when code-reader-transport--handler
    (code-reader--safely (format "handling %s message" (plist-get message :type))
      (funcall code-reader-transport--handler message))))

(defun code-reader-transport--filter (process chunk)
  "Process filter: decode CHUNK from PROCESS and dispatch each complete line."
  (code-reader--safely "engine output"
    (when (eq process code-reader-transport--conn)
      (let ((split (code-reader-transport-decode-chunk code-reader-transport--input chunk)))
        (setq code-reader-transport--input (cdr split))
        (dolist (line (car split))
          (let ((message (code-reader-transport-parse-line line)))
            (when message
              (code-reader-transport--handle message))))))))

;;; Connecting

(defun code-reader-transport--finish (error)
  "Complete the pending connect requests.  ERROR is nil on success or a string."
  (when code-reader-transport--timer
    (cancel-timer code-reader-transport--timer)
    (setq code-reader-transport--timer nil))
  (when (and error (code-reader-transport--connecting-p))
    (delete-process code-reader-transport--conn)
    (setq code-reader-transport--conn nil))
  (let ((waiters (reverse code-reader-transport--waiters)))
    (setq code-reader-transport--waiters nil)
    (when (and (null error) waiters)
      (code-reader--safely "ping"
        (code-reader--send '(:type "ping"))))
    (dolist (callback waiters)
      (code-reader--safely "connect callback"
        (funcall callback error)))))

(defun code-reader-transport--connection-sentinel (process event)
  "Sentinel for the engine socket PROCESS.  EVENT describes the state change."
  (code-reader--safely "connection sentinel"
    (when (eq process code-reader-transport--conn)
      (cond
       ((string-prefix-p "open" event)
        (setq code-reader-transport--open t)
        (code-reader-transport--finish nil))
       ((not (process-live-p process))
        (let ((was-open code-reader-transport--open))
          (setq code-reader-transport--conn nil
                code-reader-transport--open nil)
          (when was-open
            (code-reader-transport--handle
             (list :type "disconnected" :reason (string-trim event))))))))))

(defun code-reader-transport--probe ()
  "Start one non-blocking connection attempt to the engine socket."
  (when (and code-reader-transport--conn
             (not (code-reader-transport-connected-p)))
    (delete-process code-reader-transport--conn))
  (setq code-reader-transport--input "")
  (setq code-reader-transport--conn
        (condition-case err
            (make-network-process
             :name "code-reader-engine-connection"
             :family 'local
             :service (code-reader-transport-socket-path)
             :coding 'binary
             :noquery t
             :nowait t
             :filter #'code-reader-transport--filter
             :sentinel #'code-reader-transport--connection-sentinel)
          (error
           (code-reader--log "connection attempt failed: %s" (error-message-string err))
           nil))))

(defun code-reader-transport--engine-sentinel (process event)
  "Sentinel for the engine PROCESS; log when it exits."
  (code-reader--safely "engine sentinel"
    (unless (process-live-p process)
      (code-reader--log "engine exited: %s" (string-trim event))
      (when (eq process code-reader-transport--engine)
        (setq code-reader-transport--engine nil)))))

(defun code-reader-transport--start-engine ()
  "Start the engine process.  Return nil on success, or an error string."
  (condition-case err
      (let* ((socket (code-reader-transport-socket-path))
             (state-dir (code-reader-transport-state-directory))
             (command (code-reader-transport-engine-command socket))
             (default-directory (file-name-as-directory code-reader-package-root)))
        (make-directory state-dir t)
        (setq code-reader-transport--engine
              (make-process :name "code-reader-engine"
                            :command command
                            :buffer nil
                            :stderr (get-buffer-create code-reader-engine-buffer-name)
                            :connection-type 'pipe
                            :noquery t
                            :sentinel #'code-reader-transport--engine-sentinel))
        (code-reader--log "started engine: %s" (string-join command " "))
        nil)
    (error (format "cannot start the engine: %s" (error-message-string err)))))

(defun code-reader-transport--tick ()
  "Timer callback: retry the connection, start the engine if needed, or stop."
  (code-reader--safely "connect retry"
    (cond
     ((code-reader-transport-connected-p)
      (code-reader-transport--finish nil))
     ((code-reader-transport--connecting-p) nil)
     ((>= code-reader-transport--attempts code-reader-transport-max-attempts)
      (code-reader-transport--finish
       "the engine did not accept connections (see *code-reader-engine*)"))
     (t
      (cl-incf code-reader-transport--attempts)
      (cond
       ((and (not code-reader-transport--engine-started)
             (not (code-reader-transport--engine-live-p)))
        (setq code-reader-transport--engine-started t)
        (let ((error-message (code-reader-transport--start-engine)))
          (if error-message
              (code-reader-transport--finish error-message)
            (code-reader-transport--probe))))
       ((and code-reader-transport--engine-started
             (not (code-reader-transport--engine-live-p)))
        (code-reader-transport--finish
         "the engine process exited (see *code-reader-engine*)"))
       (t (code-reader-transport--probe)))))))

(defun code-reader-transport-connect (callback)
  "Make sure the engine is connected, then call CALLBACK.
CALLBACK receives nil on success or an error string.  The call never waits:
when the engine is not yet connected, the answer arrives later from a timer or
process sentinel.  When already connected, CALLBACK runs before this returns."
  (code-reader-transport-socket-path)
  (cond
   ((code-reader-transport-connected-p)
    (funcall callback nil))
   (t
    (push callback code-reader-transport--waiters)
    (unless code-reader-transport--timer
      (setq code-reader-transport--attempts 0
            code-reader-transport--engine-started nil
            code-reader-transport--open nil)
      (code-reader-transport--probe)
      (setq code-reader-transport--timer
            (run-at-time 0.05 code-reader-transport-retry-interval
                         #'code-reader-transport--tick))))))

(defun code-reader-transport-shutdown ()
  "Stop the engine: send `shutdown' if connected, else delete our process.
Return a short description of what was done."
  (cond
   ((code-reader-transport-connected-p)
    (code-reader--send '(:type "shutdown"))
    "sent shutdown to the engine")
   ((code-reader-transport--engine-live-p)
    (delete-process code-reader-transport--engine)
    (setq code-reader-transport--engine nil)
    "stopped the engine process")
   (t "no engine is running")))

(defun code-reader-transport--on-emacs-exit ()
  "Kill hook: shut the engine down so that it does not outlive Emacs."
  (code-reader--safely "engine shutdown on exit"
    (code-reader-transport-shutdown)))

(add-hook 'kill-emacs-hook #'code-reader-transport--on-emacs-exit)

(provide 'code-reader-transport)
;;; code-reader-transport.el ends here
