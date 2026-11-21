# devPaste - Engineering State

## Status

Personal class. Version 0.2.0. All of the v2.0 spec is written (M1 to M3, plus the M1 gaps). M1 compiled and ran on 20 November 2026. **The M2 and M3 code (0.2.0) has not been compiled yet.** It was written in a session with no Swift toolchain. Next: build, fix any errors, run `./smoke.sh`, then the manual checks below. **The 21 November UI changes (themes, transparency, About, resizable Settings, right-click carousel) are not compiled either.**

## What it is

A menu bar app that keeps a searchable history of what Nino copies, and a library of Quick Snippets, and pastes either back into the app he came from. It also does OCR on images, a paste queue, combined paste, edit and transform, export and import, and daily snippet backups.

## Current architecture

- Two ways to build the same sources. `devPaste.xcodeproj` (app target, `DevPasteCore` framework, test bundle, shared scheme; folder-synced groups, Xcode 16 or later). And `Package.swift` with `build.sh` and `smoke.sh` for the command line. Keep them in step if targets change.
- Minimum macOS 15 (needed by DevVisuals.swift). Built for Nino's current macOS only. No App Store, no sandbox.
- **Capture:** polls `NSPasteboard.general.changeCount` every 250 ms after activity, 750 ms when idle. Stops on sleep, while locked and in Presentation mode. Adds a bookmark to file references so moved files can be found.
- **Privacy:** concealed, transient and auto-generated markers skipped; excluded apps checked against every app active in the last 1.5 s and the nspasteboard source; decided before any payload is read. Presentation mode hides previews and pauses capture.
- **History store:** `~/Library/Application Support/devPaste/history/history.sqlite` (WAL, FTS5, **schema v2**: v1 plus a `derived` table for OCR) and `blobs/`. Never backed up. Not encrypted (decision 0002). Migration from v1 takes a `VACUUM INTO` copy first (N3).
- **Snippet store:** `.../snippets/snippets.sqlite` (schema v1). Categories, tags, favourites, manual order, shortcuts, last 10 revisions, FTS5. Everything in one file so a backup is one consistent copy. Stored file copies live inside it (50 MB each at most).
- **Backups:** `SnippetBackupService`. Daily (checked at launch and hourly): `VACUUM INTO` to `.../backups/`, opened and checked, last 14 kept, then copied to the NAS folder in Settings. Restore uses SQLite's online backup API after saving the current snippets first.
- **OCR:** Vision `VNRecognizeTextRequest`, accurate, en-US, one image at a time on a utility queue, images downsampled to 4096 px. Results stored as derived data and appended to the search text behind a marker; deleting OCR restores the original search text.
- **Paste:** nonactivating panel, so the source app stays frontmost. Writes content (internal types stripped, moved files resolved, stored copies written to `paste-files/`), checks Accessibility, target running and frontmost, no secure input, then posts ⌘V. Otherwise copy only, with a message.
- **Queue:** in memory only. Snapshots taken when added. One item per shortcut press, advancing only after the paste event is sent. Clears after 10 idle minutes, on lock and on quit.
- **Hot keys:** Carbon `RegisterEventHotKey`. Panel (default ⌃⌥V), queue next and resend (no default), one per snippet. Clashes with devPaste's own shortcuts and other snippets are checked; clashes with other apps show as "Taken by another app".
- **UI:** SwiftUI in an NSPanel. Editors and dialogs are overlays inside the panel so focus never leaves it. DevVisuals.swift 1.1 copied unchanged (`\.areaAccent`, `PrimaryCapsule`, `SoftCapsule`, `IconTile`, `AccentCard`, `AccentWash`, `TranslucencyCurve`). Area colours and wash tuning in `AreaStyle.swift`.
- **Themes:** `Theme.swift`. System (default), Golden, Dark Slate, Marine, Madder, as devThink; every colour editable and resettable; transparency slider. `Themed` applies them to the panel, Settings and About (AppKit windows, so its own behind-window blur; see decision 0003). Area colours stay the panel accent on every theme. UserDefaults keys `theme.*`.
- **Carousel:** `CarouselController.swift`. Right-click (or Control-click) on the menu bar icon drops a small non-activating panel under the icon with the last 4 copies or the first 4 snippets (snippet sort order), as pictures: image thumbnails, text excerpts, or type tiles. Click or 1 to 4 copies the item (the same path as Copy, so it is not re-captured); Escape or a click elsewhere closes it. Presentation mode hides contents. Left click still opens the menu, which is now attached only while it is shown. Setting: `carouselSource` (General).
- **Windows:** Settings is resizable (minimum 560 by 460) and remembers size and position. About (status menu) shows version, build time, schemas, what is stored and where, in devThink's layout.
- No network. No ports. Nothing exposed.

## Decisions

| Date | Decision | Reason | Record |
| --- | --- | --- | --- |
| 20 Nov 2026 | Menu bar app with no app menu bar | Normal for this kind of utility | 0001 |
| 20 Nov 2026 | History store not separately encrypted | Never backed up; FileVault; single user | 0002 |
| 20 Nov 2026 | Visual layer used in part | Utility panel, no overview screens | 0003 |
| 20 Nov 2026 | Xcode project and Swift package side by side | Xcode for daily work, package for the scripted smoke test | 0004 |
| 20 Nov 2026 | Export is one unencrypted JSON file; Presentation mode is manual | Simplest useful; automatic screen-share detection is unreliable | 0005 |
| 20 Nov 2026 | Space toggles the preview only when the search is empty; ⌘Y always does | Search always has focus so typing works at once | - |
| 20 Nov 2026 | Area colours: Clipboard #1E8A9E, Quick Snippets #8A5CD6 | Both pass VISUAL_DESIGN rule 1 | - |
| 20 Nov 2026 | Return with several items selected opens Combine | One obvious action for a multi-selection | - |
| 20 Nov 2026 | Editing rich text in a snippet saves plain text, with a warning | The spec's lightweight editor is plain text | - |
| 20 Nov 2026 | Locate copies the found file rather than rewriting history | History sources are immutable | - |
| 20 Nov 2026 | Smoke test does not paste into TextEdit | The spec says never automate paste against real documents; done by hand instead | - |
| 20 Nov 2026 | OCR language fixed to en-US | Covers UK English text; other languages after use shows a need | - |
| 21 Nov 2026 | Colour themes and transparency, as devThink; theme accent tints Settings only | Areas keep their colour on every theme; both pass 3:1 on white and black | 0003 |
| 21 Nov 2026 | Panel blur stays on when devPaste is not active | The panel never makes devPaste active, so a following blur would always be flat | 0003 |
| 21 Nov 2026 | Right-click carousel copies, it does not paste | Asked for copy; keeps Nino in control of where it goes | - |
| 21 Nov 2026 | Carousel snippets follow the snippet sort, not recency | Snippets have no last-used time; the sort is what Nino already chose | - |
| 21 Nov 2026 | Carousel never activates devPaste | The app you came from stays in front, so ⌘V works at once | - |
| 21 Nov 2026 | About in the status menu, devThink layout | No app menu bar (0001) | - |
| 20 Nov 2026 | App icon added: clipboard on a stack of teal and purple cards, dark tile | Uses the two area colours; source is `App/AppIcon.svg`. Xcode uses `Sources/devPaste/Assets.xcassets`, build.sh copies `App/AppIcon.icns` | - |

## Manual checks (record results here)

| Check | Result |
| --- | --- |
| App icon shows in Finder, Spotlight and /Applications (both builds) | Not yet checked |
| Pasteboard privacy prompt on current macOS? | Not seen during M1 use |
| Direct paste into Word, Outlook, VS Code, Safari, Notes, TextEdit | M1: working (Nino, 20 Nov). Re-check after 0.2.0 |
| Snippet shortcut pastes into the front app | Not yet checked |
| Queue: five items, one per press, resend works, clears on lock | Not yet checked |
| Combined paste order and separator | Not yet checked |
| OCR finds text in a screenshot; search finds it | Not yet checked |
| Moved file: shows "Moved to", pastes the new location; deleted file shows Unavailable and Locate | Not yet checked |
| Snippet backup appears in `backups/` and on the NAS | Not yet checked |
| **Restore test (N4)**: restore a backup, confirm snippets come back | **Not yet done. Required.** |
| Export then import into a fresh store | Not yet checked |
| Presentation mode hides previews and stops capture | Not yet checked |
| VoiceOver and keyboard-only through paste, save snippet, queue | Not yet checked |
| Each theme on the panel, Settings and About: readable, light and dark | Not yet checked |
| Transparency at 0, 0.5 and 1 on the panel while another app is in front; Reduce Transparency forces solid | Not yet checked |
| Settings resizes, keeps its size across tabs and relaunch | Not yet checked |
| About shows version, build time and counts | Not yet checked |
| Right-click shows the carousel under the icon; left click still shows the menu; Control-click works | Not yet checked |
| Carousel: click and 1 to 4 copy, ⌘V pastes in the front app, item not captured twice; switch to snippets in Settings | Not yet checked |

## Open items

- Compile 0.2.0 and fix errors. Waits on Nino.
- Manual checks above, especially the restore test.
- devDesign backup register row added for devPaste snippets (REFERENCE_ARCHITECTURE.md). The off-site column stays a gap, as for other datasets.
- Add devPaste to `~/devUtils/devProjectStatus.html`.

## Known problems

- ⌘V is posted by physical key position. Correct on UK and US layouts.
- A very large copy is read into memory before the 50 MB check can refuse it.
- Pasting into remote desktops and virtual machines is untested.
- The panel closes when it loses focus, including when Settings opens, unless an editor has unsaved changes.
- Export, import, restore and Locate use standard Mac dialogs, which close the panel.
- Rich text cannot be edited with its formatting; editing makes it plain.
- Onboarding is a single dialog.

## Run, stop, recover, back up

See README.md.

## Last verified

20 November 2026. M1 built and used by Nino. For 0.2.0: SQL for snippets (schema, ranking, revision pruning, category delete, cascades, backup, restore) and for OCR (v1 to v2 migration, search text update) checked against SQLite 3.53 in Python. Not checked: any of the 0.2.0 Swift. Nothing in 0.2.0 has been compiled, unit tested or run.

## Session log

- **21 Nov 2026 (later).** Right-click carousel of the last 4 copies or first 4 snippets, with a General setting. Originals in `build/pre-carousel-2026-11-21/`. Not compiled.

- **21 Nov 2026.** Shared UI style applied further: light AccentWash on the panel, serif titles, AccentCard for the unsaved-changes bar, theme-aware cards. Colours tab (themes, edits, transparency). Resizable Settings. About window. Decision 0003 revised. Originals of changed files kept in `build/pre-ui-2026-11-21/`. Not compiled (no Swift toolchain in the session).

- **20 Nov 2026 (evening).** Built M2 and M3 and the M1 gaps: Quick Snippets (categories, tags, favourites, order, revisions, shortcuts), search both views, multi-select, edit and transform, combined paste, paste queue, OCR, file bookmarks and Locate, export and import, daily snippet backup and restore, Presentation mode, Shortcuts and Data settings. History schema v2. Version 0.2.0. Not compiled.
- **20 Nov 2026 (later).** First compile: one error fixed. Added `devPaste.xcodeproj`. M1 working.
- **20 Nov 2026.** Spec v2.0 (Personal) and commercial v2.0 written from v1.0. M1 code, tests, build and smoke scripts, decision records written.
