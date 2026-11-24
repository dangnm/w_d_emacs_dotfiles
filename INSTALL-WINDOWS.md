# Installing Doom Emacs on Windows

How to set up Doom Emacs on Windows for this dotfiles repo, with the problems hit during the first setup (2026-11-24) and how each was handled.

## Status (as of 2026-11-24)

| Step | Result |
| --- | --- |
| Doom core cloned to `~/.config/emacs` | Done (commit `8b9b1ea`) |
| `doom doctor` | 0 errors, 5 optional warnings |
| `doom sync` with `literate` disabled | Done: 124 packages up to date |
| `config.org` symlink into `~/.config/doom` | Done, but needs an admin or Developer Mode step |
| Emacs starts with this config | **Not verified yet** |
| Manual tangle of `config.org` | **Not tested yet** |

## Before you start

> **Back up `~/.doom.d` before running `doom install`.**
> The first `doom install` run overwrote `init.el`, `config.el`, and `packages.el`
> in `~/.doom.d` even though it printed `Skipping ~/.doom.d/ (already exists)`.
> The originals could not be recovered (no git copy, no shadow copies, empty
> Recycle Bin). Back up first:
>
> ```powershell
> Copy-Item -Recurse "$HOME\.doom.d" "$HOME\.doom.d.bak-$(Get-Date -Format yyyyMMdd)"
> ```

## 1. Prerequisites

| Tool | Required | Notes |
| --- | --- | --- |
| GNU Emacs | Yes | 27.1–31.1 supported, 31.1 recommended. Avoid pre-release builds (version ends in `.50`, `.9x`, etc.). |
| Git | Yes | 2.23 or newer. Git for Windows also provides Git Bash. |
| ripgrep (`rg`) | Yes | 11.0 or newer. `doom doctor` reports an error without it. |
| fd | Optional | 7.3.0 or newer. Speeds up file indexing. |

Install ripgrep and fd with winget:

```powershell
winget install --id BurntSushi.ripgrep.MSVC -e
winget install --id sharkdp.fd -e
```

Notes from this setup:
- winget put the binaries under `%LOCALAPPDATA%\Microsoft\WinGet\Packages\...`, and did not create `%LOCALAPPDATA%\Microsoft\WinGet\Links`. Both package folders were already on the user PATH.
- A terminal opened before the install has a stale PATH. Open a **new** terminal and check:

```powershell
rg --version
fd --version
```

Install Emacs from https://ftp.gnu.org/gnu/emacs/windows/ and note the full path to `emacs.exe`. It is often not on PATH. Check with:

```powershell
Get-Command emacs.exe -ErrorAction SilentlyContinue
```

If nothing prints, set `EMACS` to the full path (used in every command below). Our machine has it at `H:\Program Files\Emacs\emacs-31.1\bin\emacs.exe`. An old PATH entry pointing to `emacs-29.2` was also present and stale.

**HOME:** Doom expects `HOME` to be `C:\Users\<you>`. If Emacs uses `C:\Users\<you>\AppData\Roaming` instead, set a user environment variable `HOME=C:\Users\<you>` and restart.

## 2. Install Doom core

Clone Doom core into `~/.config/emacs`, the path this repo's `config.org` expects:

```sh
git clone --depth 1 https://github.com/doomemacs/core ~/.config/emacs
```

Then run the installer **from an interactive terminal**. It asks questions, and running it without a terminal fails with `End of file during parsing: Error reading from stdin`.

**PowerShell** (verified on this machine):

```powershell
$env:EMACS = "H:\Program Files\Emacs\emacs-31.1\bin\emacs.exe"
cd $HOME\.config\emacs\bin
powershell -NoProfile -ExecutionPolicy Bypass -File .\doom.ps1 install
```

**Git Bash** (`~/.config/emacs/bin/doom install`) has not worked on this machine. Its launcher breaks when the Emacs path contains spaces (see troubleshooting), so use PowerShell unless you have a space-free Emacs path.

Answer the prompts:
- `Generate an envvar file? (y or n)`: answer **`n`**. On Windows, answering `y` makes the installer call `doom sync --env` by name, which fails with `The term 'doom' is not recognized` because `bin` is not on PATH. Emacs already inherits your Windows PATH, so the envvar file isn't needed.
- `Select coding system (default utf-8)`: press Enter.

Do not run `bin\doom-install` directly. It is an internal subcommand file, not an entry point. Use `doom` or `doom.ps1`.

## 3. Link this repo's `config.org`

Doom's private folder is `~/.config/doom`. Link the repo's `config.org` into it:

```powershell
# Run in an Administrator PowerShell, or after enabling Developer Mode
New-Item -ItemType SymbolicLink -Path "$HOME\.config\doom\config.org" -Target "H:\w_d_emacs_dotfiles\config.org"
```

A normal PowerShell fails with `Administrator privilege required for this operation`. To avoid running elevated each time, enable **Settings > System > For developers > Developer Mode**, then run the same command normally.

Hard links are not an alternative here: they cannot cross drives (the repo is on `H:`, the home folder on `C:`). A plain copy goes stale after each edit, and Doom's repo-relative path helpers need the symlink.

Verify it:

```powershell
Get-Item "$HOME\.config\doom\config.org" | Select-Object LinkType, Target
```

It should show `SymbolicLink` and the repo path.

## 4. Windows workaround: keep `literate` disabled

Doom's `literate` module tangles `config.org` into `config.el` during `doom sync`, then restarts Doom to finish. On Windows the restart fails, and the sync stops partway, leaving Doom incomplete. Symptoms are described in the troubleshooting table.

The current working setup keeps `literate` **disabled** in `~/.config/doom/init.el`:

```elisp
:config
;;literate
(default +bindings +smartparens))
```

`config.el` must then be produced another way. The earlier literate run tangled it successfully, so it already exists in `~/.config/doom/config.el` (745 lines). After you edit `config.org`:

1. Open `config.org` in Emacs.
2. Run `M-x org-babel-tangle`.
3. Check where `config.el` was written. It should be `~/.config/doom/config.el`. If it went somewhere else, fix the `:tangle` targets before continuing.

**This manual tangle has not been tested on this machine yet.**

## 5. Sync and verify

```powershell
$env:EMACS = "H:\Program Files\Emacs\emacs-31.1\bin\emacs.exe"
powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\.config\emacs\bin\doom.ps1" sync
powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\.config\emacs\bin\doom.ps1" doctor
```

`sync` took about 26 seconds once packages were cloned. The first run takes much longer, since it clones every package. `doctor` should report 0 errors.

Expected warnings on Windows, all optional:
- `unable to detect fonts because fontconfig isn't installed`
- `Emacs was not built with native compilation support` (the Emacs 31.1 installer build; slower but works)
- `Couldn't find a markdown compiler`, `Couldn't find shellcheck`
- `Symlinks are not enabled on this operating system`
- `Detected a non-POSIX compliant shell (cmdproxy.exe)`

## 6. Starting Emacs with this install

Doom core is now in `~/.config/emacs`. Emacs uses `~/.emacs.d` **if it exists**, so an older install there takes precedence. On this machine `~/.emacs.d` was a junction to `C:\Users\wilber\AppData\Roaming\.emacs.d`. We renamed the junction to `~/.emacs.d.old` and then removed it. Removing a junction should remove only the link, not its target.

Options:
- Remove or rename the old link, as above. Snapshot the target folder before changing anything (see lessons).
- Or start the new install explicitly with `emacs --init-directory "$HOME\.config\emacs"`. **Not verified:** a batch-mode check showed `user-init-file` as `nil`, so that check could not confirm the config loads.

Once Emacs is running, `M-: user-emacs-directory RET` shows which directory it loaded.

## 7. Version note

This repo's `config.org` was written for Doom v2.2.4 (commit `6bdd928`). The current Doom core `master` may behave differently. To match the config exactly, fetch the full history and check out that commit:

```sh
git -C ~/.config/emacs fetch --unshallow
git -C ~/.config/emacs checkout 6bdd928
```

Then run `doom sync` again.

## 8. Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `End of file during parsing: Error reading from stdin` | Installer run without an interactive terminal | Run it in a real terminal |
| `The term 'doom' is not recognized` (PowerShell) | `doom` has no PowerShell command; `bin` is not on PATH | Use `doom.ps1` with `powershell -ExecutionPolicy Bypass -File` |
| `.\doom-install` does nothing | Internal subcommand file, not an entry point | Use `doom.ps1 install` |
| `/h/Program: No such file or directory` (Git Bash) | `EMACS` path contains spaces; the launcher does not quote it | Use `doom.ps1`, or a path without spaces |
| `failed to run Emacs with command 'emacs'` (Git Bash) | The launcher's child-shell check fails. Not resolved. | Use `doom.ps1` instead |
| `__NOTANGLE=1 $@ ... not recognized` (PowerShell) | `literate` restart uses bash-only syntax | Keep `literate` disabled (section 4) |
| `envvar-missing "__DOOMSTEP"` | Running `emacs --batch ... -- sync` directly skips the launcher | Use `doom.ps1` |
| `Script was abruptly aborted, leaving Doom in an incomplete state!` | A sync stopped partway | Run `doom sync` again with `literate` disabled |
| `Administrator privilege required for this operation` | Symlink creation needs admin or Developer Mode | Section 3 |
| `Couldn't find the rg binary` in doctor | Terminal opened before the install, so PATH is stale | Open a new terminal, check `rg --version`, rerun doctor |
| `Found another Emacs config: ~/.emacs.d` | Old install still present | Section 6 |
| `Detected two private configs` | `~/.doom.d` still present | Rename it to `~/.doom.d.old` once you've confirmed `~/.config/doom` is correct |

## 9. Lessons from the first setup

- **Back up before `doom install`.** It overwrote the existing `~/.doom.d` files on the first run. The second run, under PowerShell, skipped them. Don't rely on either behavior.
- **Snapshot a folder before renaming or removing anything in it.** The old `~/.emacs.d` junction's target folder had files when I first listed it. After the junction was renamed, the target was empty. I hadn't listed it right before the rename, so I can't say what emptied it. Its last-modified time was 22:40, and the Recycle Bin was empty.
- **Remove junctions without recursion.** `Item.Delete()` on a junction removes only the link. Avoid `Remove-Item -Recurse` on a link path.
- **Use PowerShell for Doom on Windows.** The Git Bash launcher breaks on `Program Files` paths, and the `literate` restart is bash-only.
- **Open a new terminal after installing tools.** A stale PATH produced `rg not found` errors that were not real problems.
- **Check PATH for stale entries.** PATH still listed `H:\Program Files\Emacs\emacs-29.2\bin`, a folder that doesn't exist. Emacs 31.1 was at a different path.
