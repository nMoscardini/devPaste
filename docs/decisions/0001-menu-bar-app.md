# 0001 Menu bar app with no app menu bar

Date: 20 November 2026. Status: accepted. Lite record (Personal).

- **Decision.** devPaste runs as a menu bar app (`LSUIElement`) with no Dock icon and no app menu bar.
- **Why.** It is a utility summoned by a shortcut. A Dock icon and full menu bar add nothing. Shortcuts are shown in the panel footer and the menu bar icon's menu, and Settings has its own window.
- **Principle affected.** UI_PRINCIPLES section 2 (full menu bar with standard menus).
- **Reversal point.** If devPaste grows windows that need Edit or Window menus, or goes commercial.
