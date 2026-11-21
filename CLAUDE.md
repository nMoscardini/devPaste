# devPaste - CLAUDE.md

Nino's own Mac clipboard manager. Personal class.

## Read first

1. `ENGINEERING_STATE.md` - authoritative on where things stand. Update it at the end of every session.
2. `devPaste_Specification_v2_0.md` - what to build. `devPaste_Specification_commercial_v2_0.md` is not a build plan; ignore it unless Nino says he is going commercial.
3. `~/devDesign/DESIGN_PRINCIPLES.md`, `REFERENCE_ARCHITECTURE.md`, `UI_PRINCIPLES.md`, `VISUAL_DESIGN.md`.

## Rules for this project

- All of spec v2.0 is built (0.2.0). New features come from real use (principle 1), not from the commercial spec.
- `Sources/devPaste/DevVisuals.swift` is a copy of `~/devDesign/ui/DevVisuals.swift`. Never edit it here. To update, copy the new file over it and note the version in ENGINEERING_STATE.md.
- Area colours live only in `AreaStyle.swift`. Check any new colour against VISUAL_DESIGN rule 1.
- Business logic goes in `DevPasteCore` (no AppKit) with unit tests. The app target holds UI and system glue.
- Never log clipboard content. Never send anything over the network.
- History is never backed up. Snippets are, daily, with a tested restore (N4). Never copy a live SQLite file; use `VACUUM INTO` or the backup API (H2).
- Before any schema change: write the migration, back up first (N3), try it on a copy.
- Never run automated paste tests against real documents or a terminal.
- Style: short sentences, plain words, hyphens not em dashes.

## Layout

- `Sources/DevPasteCore` - models, history store, snippet store, search, capture policy, text transforms, export archive.
- `Sources/devPaste` - menu bar app: capture, paste, queue, OCR, backups, hot keys, panel, editors, settings.
- `Tests/DevPasteCoreTests` - unit tests.
- `devPaste.xcodeproj` - Xcode project (app, DevPasteCore framework, tests). Folder-synced: never add files to it by hand.
- `Package.swift`, `build.sh`, `smoke.sh` - command-line build and smoke test. Keep targets in step with the Xcode project.
- `docs/decisions` - deviation records.
