# 0003 Visual layer used in part

Date: 20 November 2026. Revised 21 November 2026. Status: accepted. Lite record (Personal).

- **Decision.** `ui/DevVisuals.swift` 1.1 is copied in unchanged. devPaste uses `\.areaAccent` (Clipboard and Quick Snippets are the areas), `PrimaryCapsule` for Paste, `SoftCapsule` for secondary actions, `IconTile` for type icons, `AccentCard` for the unsaved-changes bar, a light `AccentWash` behind the panel, serif titles on editors, dialogs, empty states and About, and colour themes with the translucency slider (`TranslucencyCurve`, `TranslucentWindow`). It does not use `HeroBand`, `ImmersiveBackdrop`, `WorldCard` or `StartCircle`.
- **Why.** devPaste is a compact utility panel with no overview screen. Hero bands and immersive backdrops would push content down and slow the main path. A wash adds the area colour without moving anything, so it is used, tuned light (`PanelWash` in `AreaStyle.swift`) to keep the established look.
- **Translucency in AppKit windows.** devPaste's panel and Settings are AppKit windows hosting SwiftUI, so `devWindowBackground` (which paints a SwiftUI scene's window container) does not reach them. `Themed` in `Theme.swift` draws the same thing as a background: an `NSVisualEffectView` behind-window blur under the theme colour, both on `TranslucencyCurve`. The panel's blur stays on when devPaste is not the active app, because it never is while you use it. Candidate for devDesign 1.2: an AppKit-window variant of `devWindowBackground`.
- **Principle affected.** VISUAL_DESIGN section 4, steps 4 and 5; section 4 "add it here first" for the AppKit backdrop.
- **Reversal point.** If devPaste gains an overview screen, or devDesign adds an AppKit backdrop (then use it and delete devPaste's).
