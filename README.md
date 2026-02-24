# claude-code-emacs-panes

Manages vterm buffers as panes for Claude Code subagents in Emacs. When Claude Code spawns subagents via `--teammate-mode tmux`, this package intercepts the tmux calls and renders each agent as a live vterm buffer you can observe and navigate.

## Requirements

- Emacs 28.1+
- vterm package
- emacsclient (ships with Emacs)
- Claude Code v2.1.47+ (`--teammate-mode tmux` flag required)
- bash (for the tmux shim script)

## Setup (Doom Emacs)

Add to `packages.el`:

```elisp
(package! claude-code-emacs-panes
  :recipe (:host github :repo "dakling/claude-code-emacs-panes"
           :files ("claude-code-emacs-panes.el" "bin")))
```

Add to `config.el`:

```elisp
(use-package! claude-code-emacs-panes
  :after-call (claude-code-ide claude-code-ide-menu)
  :config
  (claude-code-emacs-panes-setup)
  (map! :leader :prefix ("o C" . "claude panes")
        :desc "Show all panes" "a" #'claude-code-emacs-panes-show-all
        :desc "Toggle pane layout" "t" #'claude-code-emacs-panes-toggle-all
        :desc "Next pane" "n" #'claude-code-emacs-panes-next
        :desc "Previous pane" "p" #'claude-code-emacs-panes-prev
        :desc "Select pane" "s" #'claude-code-emacs-panes-select
        :desc "Dashboard" "d" #'claude-code-emacs-panes-dashboard
        :desc "Close finished panes" "K" #'claude-code-emacs-panes-close-finished
        :desc "Start Claude with panes" "c" #'claude-code-emacs-panes-start-claude
        :desc "Run smoke test" "T" #'claude-code-emacs-panes-smoke-test)
  (map! :map claude-code-emacs-panes-dashboard-mode-map
        :n "RET" #'claude-code-emacs-panes-dashboard-open
        :n "D" #'claude-code-emacs-panes-close-finished
        :n "gr" #'claude-code-emacs-panes-dashboard
        :n "q" #'quit-window))
```

Then run:

```bash
doom sync
```

## Keybindings

### SPC o C (leader prefix)

| Key | Command | Description |
|-----|---------|-------------|
| `a` | `claude-code-emacs-panes-show-all` | Show all panes side-by-side |
| `t` | `claude-code-emacs-panes-toggle-all` | Toggle between panes view and previous layout |
| `n` | `claude-code-emacs-panes-next` | Switch to next pane |
| `p` | `claude-code-emacs-panes-prev` | Switch to previous pane |
| `s` | `claude-code-emacs-panes-select` | Select pane via completing-read |
| `d` | `claude-code-emacs-panes-dashboard` | Open panes dashboard |
| `K` | `claude-code-emacs-panes-close-finished` | Kill all finished pane buffers |
| `c` | `claude-code-emacs-panes-start-claude` | Start a Claude Code session with pane env |
| `T` | `claude-code-emacs-panes-smoke-test` | Run setup verification |

### Dashboard buffer

| Key | Command |
|-----|---------|
| `RET` | Open pane at point in a split |
| `D` | Close all finished panes |
| `gr` | Refresh dashboard |
| `q` | Quit dashboard window |

## Verification

After setup, run:

```
M-x claude-code-emacs-panes-smoke-test
```

This checks that the package is loaded, the tmux shim exists and is executable, the Emacs server is running, the environment injection advice is active, and `--teammate-mode tmux` is configured. Results are reported to `*Messages*`.

## How it works

Claude Code's `--teammate-mode tmux` flag makes it manage subagents via tmux commands. This package ships a `bin/tmux` shim script that is prepended to `PATH` before launching Claude Code, so all tmux calls are intercepted. The shim translates tmux operations (new-session, send-keys, kill-session, etc.) into `emacsclient --eval` calls that create and manage vterm buffers inside Emacs. A latch-pattern validation runs on first agent spawn to verify the shim is available and executable, falling back to native tmux if not found.
