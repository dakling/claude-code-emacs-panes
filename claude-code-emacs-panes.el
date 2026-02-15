;;; claude-code-emacs-panes.el --- Manage vterm panes for Claude Code subagents -*- lexical-binding: t; -*-

;; Author: Dario Klingenberg
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (vterm "0.0.1"))
;; Keywords: tools, convenience
;; URL: https://github.com/dakling/claude-code-emacs-panes

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Manages vterm buffers as "panes" for Claude Code subagents.  A tmux shim
;; script calls into these functions via `emacsclient --eval' so that Claude
;; Code's internal tmux-based pane management is transparently redirected to
;; Emacs windows backed by vterm buffers.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

;; Avoid hard-requiring vterm at load time; the functions are available at
;; runtime when vterm buffers are actually created.
(declare-function vterm "vterm")
(declare-function vterm-send-string "vterm")
(declare-function vterm-send-return "vterm")
(declare-function vterm-mode "vterm")
(declare-function server-running-p "server")

(defvar server-name)
(defvar vterm-kill-buffer-on-exit)

;;; --- Customization group ------------------------------------------------

(defgroup claude-code-emacs-panes nil
  "Manage vterm panes for Claude Code subagents."
  :group 'tools
  :prefix "claude-code-emacs-panes-")

(defcustom claude-code-emacs-panes-min-column-width 80
  "Minimum column width for pane windows."
  :type 'integer
  :group 'claude-code-emacs-panes)

(defcustom claude-code-emacs-panes-buffer-prefix "*claude-pane:"
  "Prefix for pane buffer names."
  :type 'string
  :group 'claude-code-emacs-panes)

;;; --- State variables ----------------------------------------------------

(defvar claude-code-emacs-panes--registry (make-hash-table :test 'equal)
  "Hash: pane-id -> plist with keys :buffer :name :title :color :created-at :finished.")

(defvar claude-code-emacs-panes--next-id 0
  "Counter for synthetic pane IDs.")

(defvar claude-code-emacs-panes--sessions (make-hash-table :test 'equal)
  "Hash: session-name -> t for registered sessions.")

(defvar claude-code-emacs-panes--saved-window-config nil
  "Saved window configuration before showing panes.")

;;; --- Functions called by the shim (via emacsclient --eval) ---------------

(defun claude-code-emacs-panes-create-pane (&optional name)
  "Create a new vterm pane, optionally named NAME.
Returns the pane-id string (for use by emacsclient)."
  (require 'vterm)
  (cl-incf claude-code-emacs-panes--next-id)
  (let* ((pane-id (format "%%emacs-%d" claude-code-emacs-panes--next-id))
         (buffer-name (format "%s%s*" claude-code-emacs-panes-buffer-prefix
                              (or name pane-id)))
         (buf (generate-new-buffer buffer-name)))
    (with-current-buffer buf
      (vterm-mode)
      (setq-local vterm-kill-buffer-on-exit nil))
    (puthash pane-id
             (list :buffer buf
                   :name name
                   :title nil
                   :color nil
                   :created-at (current-time)
                   :finished nil)
             claude-code-emacs-panes--registry)
    ;; Mark pane as finished when its process exits.
    (when-let ((proc (get-buffer-process buf)))
      (set-process-sentinel
       proc
       (lambda (process _event)
         (when (memq (process-status process) '(exit signal))
           (let ((entry (gethash pane-id claude-code-emacs-panes--registry)))
             (when entry (plist-put entry :finished t)))))))
    ;; Show the buffer in some window.
    (display-buffer buf '((display-buffer-reuse-window
                           display-buffer-pop-up-window)
                          (inhibit-same-window . t)))
    pane-id))

(defun claude-code-emacs-panes-send-keys (pane-id command)
  "Send COMMAND string followed by RET to the vterm pane identified by PANE-ID.
Returns \"ok\"."
  (let* ((entry (gethash pane-id claude-code-emacs-panes--registry))
         (buf (and entry (plist-get entry :buffer))))
    (when (and buf (buffer-live-p buf))
      (with-current-buffer buf
        (vterm-send-string command)
        (vterm-send-return))))
  "ok")

(defun claude-code-emacs-panes-kill-pane (pane-id)
  "Kill the pane identified by PANE-ID and rebalance windows.
Returns \"ok\"."
  (let* ((entry (gethash pane-id claude-code-emacs-panes--registry))
         (buf (and entry (plist-get entry :buffer))))
    (when (and buf (buffer-live-p buf))
      (kill-buffer buf))
    (remhash pane-id claude-code-emacs-panes--registry))
  (claude-code-emacs-panes-rebalance)
  "ok")

(defun claude-code-emacs-panes-list-panes ()
  "Return a newline-separated string of live pane IDs."
  (let (ids)
    (maphash (lambda (id entry)
               (when (buffer-live-p (plist-get entry :buffer))
                 (push id ids)))
             claude-code-emacs-panes--registry)
    (string-join (nreverse ids) "\n")))

(defun claude-code-emacs-panes-set-pane-info (pane-id title color)
  "Set TITLE and COLOR for the pane identified by PANE-ID.
COLOR is used for a header-line indicator dot.  Returns \"ok\"."
  (let* ((entry (gethash pane-id claude-code-emacs-panes--registry))
         (buf (and entry (plist-get entry :buffer))))
    (when entry
      (plist-put entry :title title)
      (plist-put entry :color color))
    (when (and buf (buffer-live-p buf))
      (with-current-buffer buf
        (setq header-line-format
              (format " %s %s"
                      (if color
                          (propertize "\u25cf" 'face `(:foreground ,color))
                        "\u25cf")
                      (or title pane-id))))))
  "ok")

(defun claude-code-emacs-panes-send-interrupt (pane-id)
  "Send an interrupt (C-c) to the vterm pane identified by PANE-ID.
Returns \"ok\"."
  (let* ((entry (gethash pane-id claude-code-emacs-panes--registry))
         (buf (and entry (plist-get entry :buffer))))
    (when (and buf (buffer-live-p buf))
      (with-current-buffer buf
        (when-let ((proc (get-buffer-process buf)))
          (interrupt-process proc)))))
  "ok")

(defun claude-code-emacs-panes-has-session (name)
  "Return t if session NAME is registered, nil otherwise."
  (if (gethash name claude-code-emacs-panes--sessions)
      t
    nil))

(defun claude-code-emacs-panes-register-session (name)
  "Register session NAME.  Returns \"%0\" (the leader pane)."
  (puthash name t claude-code-emacs-panes--sessions)
  "%0")

(defun claude-code-emacs-panes-rebalance ()
  "Balance all windows and return \"ok\"."
  (balance-windows)
  "ok")

;;; --- Layout / Navigation Commands (interactive) -------------------------

(defun claude-code-emacs-panes--live-panes ()
  "Return an alist of (pane-id . entry) for live panes, sorted by pane-id."
  (let (result)
    (maphash (lambda (id entry)
               (when (buffer-live-p (plist-get entry :buffer))
                 (push (cons id entry) result)))
             claude-code-emacs-panes--registry)
    (sort result (lambda (a b) (string< (car a) (car b))))))

(defun claude-code-emacs-panes-show-all ()
  "Show all live panes in side-by-side vertical columns."
  (interactive)
  (setq claude-code-emacs-panes--saved-window-config (current-window-configuration))
  (delete-other-windows)
  (let* ((panes (claude-code-emacs-panes--live-panes))
         (count (length panes))
         (max-cols (max 1 (/ (frame-width) claude-code-emacs-panes-min-column-width)))
         (to-show (min count max-cols)))
    (when (> to-show 0)
      ;; Split into the required number of columns.
      (dotimes (_ (1- to-show))
        (split-window-right))
      ;; Assign buffers to windows left-to-right.
      (let ((wins (window-list nil 'no-mini)))
        (cl-loop for i from 0 below to-show
                 for win in wins
                 for pane in panes
                 do (set-window-buffer win (plist-get (cdr pane) :buffer))))
      (balance-windows))))

(defun claude-code-emacs-panes-toggle-all ()
  "Toggle between the panes view and the previous window configuration."
  (interactive)
  (if claude-code-emacs-panes--saved-window-config
      (progn
        (set-window-configuration claude-code-emacs-panes--saved-window-config)
        (setq claude-code-emacs-panes--saved-window-config nil))
    (claude-code-emacs-panes-show-all)))

(defun claude-code-emacs-panes-next ()
  "Switch to the next live pane buffer, wrapping around."
  (interactive)
  (let* ((panes (claude-code-emacs-panes--live-panes))
         (bufs (mapcar (lambda (p) (plist-get (cdr p) :buffer)) panes))
         (cur (current-buffer))
         (pos (cl-position cur bufs))
         (next (if pos
                   (nth (mod (1+ pos) (length bufs)) bufs)
                 (car bufs))))
    (when next
      (switch-to-buffer next))))

(defun claude-code-emacs-panes-prev ()
  "Switch to the previous live pane buffer, wrapping around."
  (interactive)
  (let* ((panes (claude-code-emacs-panes--live-panes))
         (bufs (mapcar (lambda (p) (plist-get (cdr p) :buffer)) panes))
         (cur (current-buffer))
         (pos (cl-position cur bufs))
         (prev (if pos
                   (nth (mod (1- pos) (length bufs)) bufs)
                 (car bufs))))
    (when prev
      (switch-to-buffer prev))))

(defun claude-code-emacs-panes-select ()
  "Select a pane buffer via `completing-read' and switch to it."
  (interactive)
  (let (candidates)
    (maphash (lambda (id entry)
               (let ((buf (plist-get entry :buffer)))
                 (when (buffer-live-p buf)
                   (push (cons (or (plist-get entry :title) id) buf)
                         candidates))))
             claude-code-emacs-panes--registry)
    (if (null candidates)
        (message "No live panes.")
      (let* ((choice (completing-read "Pane: " candidates nil t))
             (buf (cdr (assoc choice candidates))))
        (when buf
          (pop-to-buffer buf))))))

(defun claude-code-emacs-panes-dashboard ()
  "Show a tabulated dashboard of all panes."
  (interactive)
  (let ((buf (get-buffer-create "*claude-panes-dashboard*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer))
      (tabulated-list-mode)
      (setq tabulated-list-format
            [("Pane ID" 18 t)
             ("Name/Title" 30 t)
             ("Status" 10 t)
             ("Created" 20 t)])
      (let (entries)
        (maphash
         (lambda (id entry)
           (let* ((buf-live (buffer-live-p (plist-get entry :buffer)))
                  (title (or (plist-get entry :title)
                             (plist-get entry :name)
                             ""))
                  (status (cond
                           ((not buf-live) "dead")
                           ((plist-get entry :finished) "finished")
                           (t "running")))
                  (created (format-time-string "%Y-%m-%d %H:%M:%S"
                                               (plist-get entry :created-at))))
             (push (list id (vector id title status created)) entries)))
         claude-code-emacs-panes--registry)
        (setq tabulated-list-entries entries))
      (tabulated-list-init-header)
      (tabulated-list-print))
    (pop-to-buffer buf)))

;;; --- Shim directory helper ----------------------------------------------

(defvar claude-code-emacs-panes--package-dir
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory where this package is installed.
Captured at load time because `load-file-name' is nil at runtime.")

(defun claude-code-emacs-panes--shim-dir ()
  "Return the path to the bin/ directory shipped with this package."
  (expand-file-name "bin" claude-code-emacs-panes--package-dir))

;;; --- Environment injection / setup --------------------------------------

(defvar vterm-environment)

(defun claude-code-emacs-panes--env-vars ()
  "Return a list of \"KEY=VALUE\" strings for the pane environment."
  (let ((shim-dir (claude-code-emacs-panes--shim-dir))
        (pid-tag (format "%d-%d" (emacs-pid)
                         (cl-incf claude-code-emacs-panes--next-id))))
    (list (format "PATH=%s:%s" shim-dir (getenv "PATH"))
          "TMUX=emacs-panes,0,0"
          "TMUX_PANE=%0"
          "CLAUDE_CODE_EMACS_PANES=1"
          "CLAUDE_CODE_EMACS_PANES_DEBUG=1"
          (format "CLAUDE_CODE_EMACS_PANES_PID=%s" pid-tag)
          (format "EMACS_PANES_SERVER=%s" (or server-name "server")))))

(defun claude-code-emacs-panes--inject-env (orig-fn &rest args)
  "Around-advice for `claude-code-ide--start-session'.
Injects pane env vars into both `vterm-environment' (for vterm backend)
and `process-environment' (for eat backend).
ORIG-FN is the original function, ARGS are its arguments."
  (let* ((extra (claude-code-emacs-panes--env-vars))
         ;; vterm reads vterm-environment to set env vars in the terminal
         (vterm-environment (append extra (when (boundp 'vterm-environment)
                                            vterm-environment)))
         ;; eat reads process-environment
         (process-environment (append extra (cl-copy-list process-environment))))
    (apply orig-fn args)))

(defun claude-code-emacs-panes-start-claude ()
  "Start a Claude Code session with pane environment injected.
This is the main interactive entry point."
  (interactive)
  (unless (server-running-p)
    (server-start))
  (if (fboundp 'claude-code-ide)
      (let* ((extra (claude-code-emacs-panes--env-vars))
             (vterm-environment (append extra (when (boundp 'vterm-environment)
                                                vterm-environment)))
             (process-environment (append extra (cl-copy-list process-environment))))
        (claude-code-ide))
    ;; Fallback: create a plain vterm running claude.
    (require 'vterm)
    (let* ((extra (claude-code-emacs-panes--env-vars))
           (vterm-environment (append extra (when (boundp 'vterm-environment)
                                              vterm-environment)))
           (buf (generate-new-buffer "*claude-code*")))
      (with-current-buffer buf
        (vterm-mode)
        (vterm-send-string "claude")
        (vterm-send-return))
      (pop-to-buffer buf))))

(defun claude-code-emacs-panes-setup ()
  "Set up the Claude Code panes integration.
Call this from your Doom config (or init file) to wire up the
environment injection advice and ensure the Emacs server is running."
  (interactive)
  (unless (server-running-p)
    (server-start))
  ;; Advise the internal session starter, which handles both vterm and eat
  (advice-add 'claude-code-ide--start-session :around
              #'claude-code-emacs-panes--inject-env))

(provide 'claude-code-emacs-panes)
;;; claude-code-emacs-panes.el ends here
