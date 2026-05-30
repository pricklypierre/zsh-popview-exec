# Popview Exec (`pv_exec`)

## Overview

Pretty, bounded, live-scrolling command execution for zsh.`pv_exec` is a single-file zsh function that runs your shell command inside a self-contained, fixed-height, bordered popup view. It streams the command's live output into the bordered popup view, shows a spinner while it runs, and then collapses everything down to a single ✓ success line if the command exits cleanly, or keeps the view open on failure so you can see what error occurred. Think of it as a mini `tail -f` window that opens, does its job, and visually tidies up after itself.

Here is a simple example of using `pv_exec` to run a build script:

```zsh
pv_exec -l "Updating brew and all formulae..." brew update
pv_exec -l "Cleaning up brew..." brew cleanup
pv_exec -l "Running cmake configure..." -o cmake-config.log cmake -B build
pv_exec -l "Running cmake build..." -o cmake-build.log cmake --build build
```

![Installing Screencast](./readme-assets/pv_exec-opto.gif)

## Purpose

I originally wrote this for a complex long-running installer script that ran dozens of subcommands ( `git clone`, `cargo build`, `cmake`, etc.). I wanted:

- **Visibility** to see live output streaming so I know the command isn't hung.
- **Tidiness** to prevent terminal from filling with thousands of lines when everything succeeds.
- **Debuggability** to preserve the output when something actually fails.
- **Speed** so that the commands are still executed fast, even with chatty output.
- **100% zsh** for maintainability and transparency.

Existing progress and spinner tools/libraries didn't quite fit, so here we are.
## Features

- **Bounded popup scroll region** — live command output is confined to a fixed-height bordered view so your scrollback isn't spammed.
- **Animated bordered view** — the frame grows downward as output arrives and animates closed on success. A spinner animation also shows the command is executing.
- **Auto-collapse on success** — the entire bordered view is erased and replaced with a single success line.
- **Sticky on failure** — the view stays visible (with a red border) leaving error output visible for troubleshooting.
- **Optional file logging**  — saves all output with a timestamped header between runs (using argument `-o outfile`).
- **Log file links** — renders clickable `file://` hyperlinks for log files in supported terminals (iTerm2, WezTerm, Kitty, etc.).
- **Dark/light terminal aware** — auto chooses bright or dim colors schemes based on terminal background color.
- **100% zsh** — for maintainability and transparency `pv_exec` is written in pure zsh with no 3rd party dependencies.
- **Library or Command** — `source pv_exec` to use the `pv_exec` function from your own scripts, or run it directly as a standalone wrapper.
## Requirements

- **zsh** 5.8 or newer (tested on 5.9). Script loads (via `zmodload`): `terminfo`, `datetime`, `zselect`.

No other dependencies. No Python, no `awk`/`sed` in hot paths, no 3rd party scripts or libraries.
## Usage

### Library Function or Command:

Source the file from any zsh script and call its `pv_exec` function:

```zsh
source /path/to/pv_exec.zsh
pv_exec -l "Pinging google..." ping -c 5 google.com 
```

Or directly call `pv_exec.zsh` as an executable command:

```zsh
/path/to/pv_exec.zsh -l "Pinging google..." ping -c 5 google.com
```

### Synopsis

```
pv_exec [-l label] [-o outfile] [--] cmd [args...]
```

Optional command arguments:

- `-l label` Label shown above the scroll view and on success/failure lines. Defaults to the command itself.
- `-o outfile` Saves all of the command's output to `outfile`. Parent dirs are created as needed. Multiple runs with same `outfile` target append output with a timestamped separator.
- `--` Marks the end of options; everything after is the command to run.

The return code of `pv_exec` is the return code of the wrapped command.

### Custom Environment Variables

Before calling `pv_exec` you can set the following variables to customize the popup view appearance and behavior (all have sensible defaults):

| Variable | Default | Description |
| --- | --- | --- |
| `PV_ENABLE`               | `1`     | `0` to fall back to plain inline output (no popview)                |
| `PV_WRAP_LINES`           | `1`     | `1` to wrap long lines at view width, `0` to hard-truncate          |
| `PV_BORDER_SHOW`          | `1`     | `1` to draw the rounded border frame, `0` for plain indented output |
| `PV_BORDER_ANIMATE_CLOSE` | `1`     | `1` to animate the close sequence, `0` to close instantly           |
| `PV_MAX_HEIGHT`           | `13`    | Max number of output lines visible in the scroll view               |
| `PV_LOG_TO_PADDING`       | `50`    | Column at which the "logged to: ..." link is aligned                |
| `PV_CLOSE_PAUSE_DELAY`    | `1.75`  | Seconds to pause before closing the view on success                 |

---
## Limitations / Known Quirks

- The bordered view does its best to handle double-width characters, but the right border may render one column off on lines containing them, or output lines might be truncated.
- Recursive calls to `pv_exec` are not supported (limitation of using  zsh `coproc`).
- Designed for interactive TTYs; when stdout is not a TTY, behavior is undefined/untested.

---
## License

MIT License. See LICENSE.txt for details.
