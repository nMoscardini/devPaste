# devPaste

A Mac clipboard manager for Nino's own use. Personal class. The spec is `devPaste_Specification_v2_0.md`. Where it stands is in `ENGINEERING_STATE.md`.

Version 0.2.0 has every feature in the v2.0 spec: clipboard history, Quick Snippets, OCR, the paste queue, combined paste, edit and transform, export and import, daily snippet backups and Presentation mode.

## Build and install

Needs Xcode (current release) on the Mac.

```
./build.sh --install
```

This builds `build/devPaste.app`, copies it to `/Applications` and launches it. A clipboard icon appears in the menu bar.

### In Xcode

Open `devPaste.xcodeproj`. It has three targets: `devPaste` (the app), `DevPasteCore` (a framework with the logic) and `DevPasteCoreTests`. ⌘R runs the app, ⌘U runs the tests. The folders under `Sources/` and `Tests/` are synced, so new files appear in the project without adding them by hand.

Once only: select the `devPaste` project, then each target, Signing & Capabilities, and choose your team. That signs with your Apple Development certificate so macOS keeps the Accessibility permission across builds. Until then it signs to run locally and you may need to re-grant Accessibility after each build.

Xcode runs the app from its build folder, not from `/Applications`. Quit the installed copy first so there are not two running.

First launch asks whether to start capture. Nothing is kept until you say yes.

The first time you paste, macOS asks for Accessibility permission. Grant it in System Settings, Privacy & Security, Accessibility. Without it devPaste copies the item and you press ⌘V yourself.

## Use

| Key | Action |
| --- | --- |
| ⌃⌥V | Open or close the panel (change it in Settings, Shortcuts) |
| Type | Search. Words must all match, "quotes" for a phrase |
| ↑ ↓, ⇧↑ ⇧↓ | Move, or select more than one |
| ⌘-click, ⇧-click | Add to the selection, or select a range |
| ↩ | Paste. With several selected: combine them |
| ⌥↩ | Paste as plain text |
| ⌘1 to ⌘9 | Paste the numbered result |
| Tab | Switch between Clipboard and Quick Snippets |
| ⌘B | Search both views |
| ⌘S | Save the selected history item to Quick Snippets |
| ⌘E | Edit: a snippet, or edit and transform history text |
| ⌘N, ⌘D | New snippet, duplicate snippet |
| ⌥⌘↑ ⌥⌘↓ | Move a snippet up or down |
| ⇧⌘↩ | Combine the selection and paste |
| ⌘J, ⌘L | Add the selection to the paste queue, open the queue |
| ⌘P | Pin a history item, or favourite a snippet |
| ⌘⌫ | Delete (snippets ask first) |
| Space (empty search) or ⌘Y | Preview overlay when the panel is narrow |
| ⌘, | Settings |
| esc | Close an editor (asks if unsaved), the overlay, then the panel |

The paste queue's own shortcuts (paste next, resend last) have no default. Set them in Settings, Shortcuts. Snippets can each have a global shortcut, set in the snippet editor.

Pause, delete recent history and Settings are in the menu bar icon.

## Run, stop, recover

- **Run:** open `/Applications/devPaste.app`, or turn on Launch at login in Settings.
- **Stop:** menu bar icon, Quit devPaste. Or `pkill -x devPaste`.
- **Logs:** `log stream --predicate 'subsystem == "com.nino.devPaste"'`. Logs hold event names, sizes and counts, never clipboard content.
- **Data:** in `~/Library/Application Support/devPaste/`:
  - `history/` - clipboard history (`history.sqlite`, `blobs/`). Never backed up.
  - `snippets/snippets.sqlite` - Quick Snippets. Backed up.
  - `backups/` - daily snippet backups, last 14 kept. Also copied to the NAS folder chosen in Settings, Data.
  - `paste-files/` - temporary files for pasting stored file copies. Cleared after a day.
- **If history will not open:** devPaste shows the error and leaves the files untouched. Quit, move the `history` folder aside, and relaunch. History is temporary by design.
- **If snippets will not open:** do not delete anything. Quit, move `snippets` aside, relaunch, then Settings, Data, Restore from a backup.

## Back up

Clipboard history is never backed up, on purpose. The folder is excluded from Time Machine.

Quick Snippets are backed up every day: devPaste writes a consistent copy to `backups/` (SQLite `VACUUM INTO`, never a file copy of the live database), checks it opens, keeps the last 14, then copies it to the NAS folder you choose in Settings, Data. Time Machine also covers the `snippets` folder.

To restore: Settings, Data, Restore from a backup. devPaste saves your current snippets first (`backups/before-restore-…sqlite`), then replaces them. **Test this once** and record the date in `ENGINEERING_STATE.md` (N4).

Export (Settings, Data, or right-click, Export) writes a JSON file with everything inside it. It is not encrypted.

## Test

```
./smoke.sh
```

This runs the unit tests, builds the app, then runs the main path (pasteboard read, privacy policy, history, search, delete, snippets, revisions, backup, export, a transform) against temporary stores and a private pasteboard. It never touches your real clipboard or history. Then do the manual checks in `ENGINEERING_STATE.md`.

## Update

Pull or edit, then `./build.sh --install` again.
