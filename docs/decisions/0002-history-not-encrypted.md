# 0002 History store not separately encrypted

Date: 20 November 2026. Status: accepted. Lite record (Personal).

- **Decision.** The history database and blob files are not encrypted by devPaste. They rely on FileVault, folder permissions (0700) and being kept out of every backup.
- **Why.** History is never backed up or synced, so it never leaves the Mac. Encrypted full-text search needs a third-party SQLite build, which is the biggest single source of complexity for little gain on a single-user Mac.
- **Principle affected.** Principle 3 (encrypt backups holding personal data) does not apply because history has no backups. Recorded because spec v1.0 SEC06 asked for encryption.
- **Reversal point.** Going commercial, or history ever being backed up or synced.
