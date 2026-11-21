# devPaste - Commercial additions v2.0

Version 2.0 | 20 November 2026 | Nino Moscardini

This is not a build plan. It lists what would have to be added to the personal app (`devPaste_Specification_v2_0.md`) to sell it. Nothing here starts until two things are true: the personal app has been in daily use for at least three months, and Nino decides to go commercial.

## 0 Gate: hardening standard first

DESIGN_PRINCIPLES says a paid product sits outside Lab, Personal and Shared, and needs a separate hardening standard before work starts. Write that standard in devDesign first. It should cover signing, updates, security review, privacy policy, support, accessibility as a must, and data protection for customers.

## 1 Platform and distribution

- Support current macOS minus one (decide at the time).
- Signed and notarised direct download with signed updates (Sparkle or similar) and a rollback plan.
- Mac App Store build, sandboxed. Spike it first: capture, Accessibility paste, global shortcuts, file bookmarks and login items may all behave differently. Validate each channel separately.
- Both builds share one schema and a migration route. Never run two capture services at once.

## 2 Security and privacy (heavier than personal)

- **Encrypted store.** Encrypt payloads, metadata, thumbnails, OCR text and the search index at rest. Encrypted SQLite with FTS (SQLCipher or similar). Check the licence and App Store compatibility. The key lives in the Keychain. No plaintext index beside encrypted data.
- **Key recovery.** Define what happens on a new Mac or after a Keychain loss, so customers don't lose snippets.
- **App lock.** Hide content immediately and show a locked state if the key is unavailable. Never create an empty store over existing data.
- **Screen sharing.** Hide automatically during screen sharing and recording, on by default. Validate against Zoom, Teams, Meet and others. Label any limits clearly.
- **Confidential types.** Maintain a tested compatibility list of password managers and browsers that mark content.
- **Deletion wording.** Never promise forensic erasure.
- **Diagnostics.** Opt-in only, error codes and counts only, never content. App updates never include content.
- **Privacy policy and data protection review.** Customers' clipboards hold other people's data.

## 3 Export and backup for customers

- An encrypted portable archive using a user passphrase, authenticated encryption and a reviewed key-derivation design. Never export the Keychain key.
- Plain JSON only through an explicit unencrypted choice.
- Hardened import: path traversal, archive expansion limits, checksums, future schemas, no partial writes.
- On-device recovery snapshots before migrations (keep the last three), with a recovery workflow.

## 4 Product polish

- Three-step onboarding: explain capture and privacy, choose a shortcut, try a sample.
- Designed empty, paused, full storage, permission denied, migration failure and unavailable file states.
- A searchable command menu.
- VoiceOver and keyboard support as musts, plus full contrast checks.
- Help pages and a support route.
- A tested app matrix (current Word and Outlook builds, browsers, Xcode, remote desktop as best effort).

## 5 Performance and release evidence

- Targets on a reference Apple Silicon Mac with 16 GB of RAM: warm open p95 ≤ 150 ms, cold open p95 ≤ 500 ms, search p95 ≤ 100 ms across 10,000 clips and 1,000 snippets, idle CPU < 1%, memory < 150 MB.
- Record p50, p95 and worst case per release.
- Full acceptance matrix (v1.0 section 19, AT01 to AT12) passes on the oldest and newest supported macOS.
- No open data-loss, privacy, wrong-target-paste or corruption defects at release.

## 6 Workflow features (customer V1.1)

- **Rules engine.** Name, trigger, conditions, ordered actions. Test on sample. Bounded regex. No shell, scripts, network calls or auto-paste as rule actions. Loop protection.
- **Shortcuts actions.** Search snippets, get a snippet, save text, transform text.
- **CLI.** Off by default. Snippets only, through a local authenticated channel. No network listener.
- **Link previews.** Opt-in fetch, no scripts or credentials, local network blocked, size and time limits, cached with a timestamp.

## 7 Apple device sync and mobile (customer V2)

- Optional private iCloud sync. Snippets only by default. History sync is a separate choice.
- Design real end-to-end encryption before claiming it. Private iCloud alone is not proof.
- Stable IDs, change tracking, tombstones kept for at least 90 days, conflicts kept as versions, no merging across accounts.
- iPhone and iPad apps: snippets, history browsing, share-sheet capture, explicit clipboard import. Optional keyboard extension that never collects unrelated typing. Never promise background capture on iOS.

## 8 Business decisions

- Public name and trademark clearance (devPaste is a working name).
- Pricing. Starting point: a one-time Mac purchase with a clear upgrade policy. Sync and mobile costs decided later.
- Positioning against Paste, PastePal, Pastebot, Maccy, Raycast and Alfred. Their features are inspiration, not assets to copy.
- Support and refund policy.

## 9 Future evaluation

Prompted templates, text expansion, shared collections, AI or MCP access. Each needs its own spec and privacy review.
