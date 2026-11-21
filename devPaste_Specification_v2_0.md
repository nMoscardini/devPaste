# devPaste - Specification v2.0 (Personal)

Version 2.0 | 20 November 2026 | Nino Moscardini

Replaces v1.0 for building. v1.0 was a product spec. This one is a personal Mac tool built to devDesign. Everything needed to go commercial is in `devPaste_Specification_commercial_v2_0.md`.

## 1 One-page summary

- **Class.** Personal. Only Nino uses it, on his Mac Studio. Nothing reaches the internet. Clipboard content can include other people's names and emails, but only incidentally. devPaste does not extract, tag, count or report on people, so class question 2 does not apply (DESIGN_PRINCIPLES, Project classes).
- **Problem.** Copied content gets lost. Repeated text gets retyped. Moving several values between apps means going back and forth.
- **Success.** After four weeks Nino opens devPaste every day without thinking about it, and paste lands in the right app every time.
- **Riskiest assumption.** Direct paste into the previous app works reliably in Word, Outlook, Notes, Safari and VS Code, and it is quicker than what Nino does now. M0 and M1 test this.
- **Reuse check.** Read Maccy (open source, Swift) before writing capture and paste code. Fork or borrow if it saves time. Record the decision in ENGINEERING_STATE.md.
- **AI use.** None.
- **People and data.** No data about other people beyond incidental clipboard content. Nobody is ranked (N7).

## 2 What it does

A menu bar app with one floating panel and two views: **Clipboard** (copy history) and **Quick Snippets** (saved, reusable content). A list sits on the left and a full preview on the right.

### Panel
- A segmented control (Clipboard | Quick Snippets) with search underneath. Each view keeps its own query, filter and selection for the session.
- Starts at about 940 by 600 points and can be resized down to 620 by 400. Below 760 wide the preview collapses and Space opens it as an overlay. The divider position is remembered.
- Native Mac look, light and dark modes, system font. Respects Reduce Transparency, Increase Contrast and Reduce Motion. Colour never carries meaning on its own.
- The footer shows key hints, item count, the paused state and queue progress. Delete is never next to Paste.
- Opens on the display with the focused window, then the pointer's display, then the main display. Never ends up off-screen after a display change.
- Closes on Escape or a click outside, unless Keep Open is on or an edit is unsaved.

### Clipboard
- Each row shows a type icon or thumbnail, a title or two lines of text, the source app and a relative time. Link rows show the domain.
- The preview shows full text, the image fitted to the space, a PDF preview, or file details.

### Capture
- Polls the pasteboard change count about every 250 ms while active and more slowly when idle. Stops during sleep. On wake, checks once without re-importing.
- Keeps these formats: plain text, RTF, HTML, PNG, TIFF, PDF and file URLs. Multi-item copies stay together. Unsupported formats are skipped, not converted. Copied content is never run.
- Records the time, the source app (best effort, otherwise "Unknown"), formats, size and a hash.
- An exact repeat moves to the top and its copy count goes up. There is an option to keep duplicates.
- devPaste ignores its own writes but still catches a later genuine copy of the same content.
- Retention: 30 days by default (options are 1, 7, 30, 90 days or until removed), capped at 10,000 items and 1 GB. The oldest unpinned items go first.
- One copy can be at most 50 MB. Anything larger is skipped with a quiet message. Nothing is truncated and shown as if complete.
- Pinned items never expire but do count towards the cap.
- Delete options: one item, selected items, the last 5 minutes, the last hour, or everything (with a clear note on whether pinned items are included). Deleting removes thumbnails, OCR text and search entries too.

### Quick Snippets
- Create one by hand, or with Save to Quick Snippets from history (Command S). A name is required and the first line is suggested. The snippet is an independent copy.
- Types: plain text, rich text, images, URLs and files (either a stored copy or a reference with a warning).
- Categories, tags, favourites, manual order, and sorting by name, date or use. Favourites come first. Deleting a category moves its snippets to Uncategorised.
- Every save keeps a revision, up to the last ten. Restore previous version and Duplicate are available.
- Optional global shortcut per snippet, with conflict warnings and one switch to turn them all off.
- Static content only. No automatic text expansion.

### Search
- Local search across text, snippet names, tags, OCR text, file names, URLs and app names. Case-insensitive, all words must match, "quoted phrases" and partial words are supported.
- Filters: All, Text, Images, Links, Files, plus source app and date range. Searches the current view, with Search both views on demand.
- Snippets rank exact name matches first, then prefix, then content. History ranks by most recent.
- New items show immediately. Indexing catches up in the background. The index can be rebuilt from the stored content.

### Paste
- Records the frontmost app before the panel opens. On paste it writes the content, returns to that app, then sends Command V once the app is active.
- Needs Accessibility permission. Without it, devPaste copies the item and shows "Copied. Press Command V."
- If the target app has closed, a secure field is focused, or focus has moved, devPaste only copies. It never pastes somewhere else.
- It never presses Return or Tab and never submits anything.
- The pasted content stays on the clipboard. There is no timed restore of the previous clipboard.
- Option Return pastes as plain text.

### Paste queue
- Build an ordered queue from history or snippets. It shows numbers, previews, reordering and Clear queue.
- Each press of the queue shortcut pastes one item. The status shows "Insert requested", not "delivered". Previous item retries.
- The queue clears after 10 idle minutes, on lock, or on quit. It is never saved.

### Combined paste
- Joins selected text items in the chosen order with a separator: new line, blank line, comma, tab or custom. Previews before pasting. The output is plain text. Images are rejected with a reason.

### Editing and transforms
- A light editor for text and URLs. Editing history creates a new entry and keeps the original. Editing a snippet saves a revision.
- Transforms: upper case, lower case, title case, trim, remove empty lines, normalise line endings, and join wrapped PDF lines. Each shows a before and after. They work on a copy, and Save as new snippet is available.

### OCR
- On-device Vision text recognition runs on images in the background. Extract text, Copy text and Save as snippet are available. The text is stored as derived data and the image is kept.
- English to start. The state shows as Pending, Ready, No text found or Failed. It can be turned off and its data deleted.

### Files and links
- File history keeps a bookmark and details. A moved or deleted file shows as Unavailable with a Locate option.
- Thumbnails are made in the background with limits. A bad file never crashes capture.
- Links show the address and domain only. No website is fetched. Opening a link is always a deliberate action.

### Privacy
- Capture starts only after Start capture on first launch. Launch at login is off by default.
- Skips pasteboard types marked concealed, transient or auto-generated (password managers). Excluded apps are set by bundle ID and applied before anything is stored.
- Pause for 5 minutes, 15 minutes, 1 hour or until resumed, with a visible indicator.
- Capture stops and the queue clears while the screen is locked. On unlock, whatever was copied during the lock is not imported.
- A manual Presentation mode hides previews and pauses capture.
- No analytics and no network calls. Logs hold codes, timings and counts, never content.

### Export and import
- Export snippets (all or selected) and chosen history items as JSON plus attachments. Import validates everything before writing and adds items as new snippets, offering Skip or Keep both for duplicates.

### Settings
General, Shortcuts, Capture and retention, Privacy, Appearance, Data. A Settings window opens from the menu bar icon.

## 3 Keyboard

All shortcuts can be changed. These defaults avoid Command Shift V (Markdown preview in VS Code) and Control 1 to 9 (Mission Control desktops).

| Key | Action |
| --- | --- |
| Control Option V | Toggle the panel (global) |
| Tab | Switch between Clipboard and Quick Snippets |
| Type, or Command F | Search. Arrow keys move through results |
| Return | Paste |
| Option Return | Paste as plain text |
| Command 1 to 9 | Paste the numbered result |
| Space | Toggle preview (list focused) |
| Command S | Save as snippet, or save an edit |
| Command E | Edit |
| Escape | Close overlay, then the panel |
| Queue paste | No default. Set one in Settings |

## 4 Architecture

- Swift, SwiftUI for views, AppKit for the panel, focus, pasteboard and previews. A menu bar app. Business logic sits outside views so capture, search and paste can be tested on their own.
- **Target: the current macOS only.** Built and installed from Xcode. No App Store, no sandbox, no notarisation needed.
- Components: Capture service, Repository (SQLite with FTS5, plus blob files for large content), Search, Paste coordinator, Snippet service, Preview and OCR workers, Policy (exclusions and pause).
- One repository writer. Capture commits never wait for thumbnails or OCR. Background work checks for cancellation so deleted items do not come back.
- Data model: as in v1.0 section 14, minus the encryption fields.
- Store in the app's Application Support folder on local disk (H1).

### Data, backup and encryption

- **History is temporary.** It is excluded from Time Machine and the NAS backup and never backed up. N4 does not apply because losing it is acceptable.
- **Snippets are data Nino cannot recreate.** devPaste writes an automatic daily snippet export (using the SQLite backup API plus attachments, H2) to local disk, then copies it to the NAS folder chosen in Settings. Keep the last 14. Add a row to the backup register and test a restore at setup (N4).
- **Encryption.** History is never backed up and the Mac has FileVault, so the live store is not separately encrypted. Lite deviation record: protecting a single-user Mac against other local processes is not worth an encrypted-FTS dependency. Reversal point: going commercial, or history ever being backed up or synced.
- Before any schema migration, take a backup and confirm it opens (N3).

## 5 Build stages

Build in this order. Each stage is used daily before the next starts. If a feature turns out to be unused, drop it and record why.

| Stage | Contents | Done when |
| --- | --- | --- |
| M0 Spike | Pasteboard polling on current macOS (check the pasteboard privacy prompt), direct paste into Word, Outlook, VS Code, Safari and Notes, source attribution, global shortcut | Notes on each in ENGINEERING_STATE.md |
| M1 Core | Panel, capture, history, search, preview, direct paste with copy fallback, pause, exclusions, lock | Used daily for two weeks |
| M2 Snippets | Snippets, categories, favourites, revisions, shortcuts, retention, export and import, daily snippet backup, restore tested | Restore proven |
| M3 Power | OCR, queue, combined paste, editor, transforms, multi-display polish, Presentation mode | Each used for real at least once |

## 6 Verification

- Smoke test: one command launches the app against a temporary store, copies a text and an image through a test pasteboard, searches, and pastes into TextEdit.
- Unit tests: dedup, retention and eviction, exclusions before storage, transforms, import validation, migration.
- By hand: paste into Word, Outlook, Notes, Safari, VS Code and TextEdit. Close the target mid-paste. Focus a password field. Lock and unlock. Restore snippets from the NAS export.
- Never run automated paste tests against real documents or a terminal.

## 7 devDesign notes

- UI_PRINCIPLES applies. A menu bar app without a full menu bar is a lite deviation (normal for this kind of tool).
- VISUAL_DESIGN: not adopted, apart from optional area colours for the two views. No hero bands or immersive screens in a utility panel.

## 8 Later, only if real use asks

- Rules (skip capture from an app or pattern, auto-tag, retention per type)
- Shortcuts app actions
- Per-app plain-text default
