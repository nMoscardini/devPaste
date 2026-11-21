# 0005 Unencrypted JSON export, manual Presentation mode

Date: 20 November 2026. Status: accepted. Lite record (Personal).

- **Decision.** Export writes one JSON file with attachments inside it (base64, each with size and SHA-256), unencrypted. Presentation mode is a manual switch; devPaste does not try to detect screen sharing.
- **Why.** Export is for moving or keeping snippets by hand; the daily backup is the real safety net. An encrypted archive with a passphrase and key derivation is product work (commercial v2.0). Screen-share detection is unreliable across apps, and a switch that always works beats a guess that sometimes does not.
- **Principle affected.** Principle 3 (encrypt backups holding personal data): the export is not the backup, and the Settings text says it is unencrypted. Spec v1.0 SEC05 and DAT01.
- **Reversal point.** Going commercial, or exports being kept anywhere other than Nino's own machines.
