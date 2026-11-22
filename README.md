# Lapang

A Mac window that shows how much disk space is left, what is eating it, and cleans the known
leftovers once you say so. It was made after this Mac's 488 GB SSD went down to 9 GB free in
November 2026. Each rule below is something that cleanup found.

## What it looks after

| Rule | Where | Offered for cleaning when |
|---|---|---|
| Test browser profiles | Folders in `$TMPDIR` that hold a Chrome profile (`Default/Preferences`) or start with `playwright_chromiumdev_profile-`, `playwright_firefoxdev_profile-`, `puppeteer_dev_chrome_profile-`, `puppeteer_dev_firefox_profile-` | nothing inside changed for 2 hours |
| Headless Chrome scratch | `scoped_dir*` in `~/Library/Caches/Google/Chrome-headless` and `$TMPDIR` | nothing inside changed for 2 hours |
| Claude session temp | `/private/tmp/claude-<uid>/<project>/<session>` | nothing inside changed for 2 days |
| Old subagent logs | `<account>/projects/<project>/<session>/subagents` in every `~/.ccs/instances/*` and `~/.claude` | nothing inside changed for 3 days |
| Package caches | `pnpm store prune`, `npm cache clean --force` | you tick the command |
| Grew in the last day | Folders under `~/Developer`, `~/Library/Application Support`, `~/Library/Caches`, `~/.cache`, `~/.ccs/instances`, `~/Downloads`, `~/Desktop`, `$TMPDIR` and `/private/tmp` where more than 1 GB was written in 24 hours | never: watch only, with Show in Finder |

The idle times are in Settings (⌘,). Each rule also counts what appeared in the last day, which
is how a leak shows up: one project's check scripts once made about 100 browser profiles a day.

Lapang never touches a main Claude transcript (`<session>.jsonl`) or anything under `memory/`.

## How deleting works

- Nothing is deleted on its own. Every rule has a Review sheet listing each folder with its size and
  idle time. Each folder has a checkbox, and the one button names the total.
- Right before a folder goes, it is checked again. It must still be a real folder (not a symlink),
  still inside its rule's folder once every symlink in the path is resolved, on the same volume, and
  still idle. Anything else is kept and listed with the reason.
- Deleting never follows a symlink and never enters another volume.
- Every outcome is one line in `~/Library/Logs/Lapang/deleted.log`, with tab-separated fields:
  time, rule, outcome, bytes, path.

## Free space

The big number is what Finder shows. It includes purgeable space, which macOS empties when an app
needs room. The legend also shows the unused part, which is what `df` reports. The number refreshes
every minute. A full scan runs when the window opens and on ⌘R.

## Build and run

Only the Command Line Tools are needed (Swift 6.2 or later, macOS 26).

```sh
scripts/test.sh             # the tests (Swift Testing)
swift run Lapang            # run from the package
scripts/make-icon.sh        # draw Support/AppIcon.icns
scripts/bundle-app.sh       # build/Lapang.app, ad hoc signed, Hardened Runtime on
```

Then copy `build/Lapang.app` to `/Applications`.

The app is not sandboxed, because the App Sandbox would block `$TMPDIR`, `/private/tmp`, `~/.ccs`
and `~/Library/Caches`. The first scan asks once for access to Desktop and Downloads. If you
decline, the growth watch skips those two folders.

pnpm and npm are found on the PATH of an interactive zsh, which reads `~/.zshrc`. An app opened
from Finder has no other way to see the fnm and pnpm setup.

`.build/debug/Lapang --snapshot=<folder>` (debug builds only) draws the window to PNG files at each
stage of a real scan, in light and dark. It opens the review sheets and closes them without
deleting anything.

## Not yet

- Worktree folders with no unsaved work (`node_modules`, `vendor`)
- The Claude desktop VM
- Chrome's AI model
- A low-space notification
- A reading in the menu bar

The app icon is a first draft: the window's capacity bar on a light tile.
