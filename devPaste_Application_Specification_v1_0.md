# devPaste

## Full application specification

Version 1.0  |  18 November 2026  |  Prepared for Nino Moscardini

devPaste is a native Mac clipboard manager with two clear views: Clipboard for recovering copied content and Quick Snippets for inserting reusable content. A searchable list and a full preview share one floating panel. Speed, reliable formatting and control over private information take priority.

This document defines the proposed product, release scope, user experience, functional requirements, architecture, data handling and acceptance criteria. It is a development specification, not a statement of implemented functionality. Platform and distribution assumptions require validation during the initial engineering spike.

## 1 Product goals and success measures

Reduce the effort of finding and reusing copied content. Keep routine use within the keyboard. Make permanent snippets easy to create without turning temporary history into a general document repository. Preserve the source content unless the user explicitly chooses a transformation.

| Measure | Release target |
| --- | --- |
| Time to paste | A recent item takes one panel shortcut, one selection action and Return. Number shortcuts paste visible results directly. |
| Panel responsiveness | Warm opening p95 at or below 150 ms on the reference Mac. Cold opening p95 at or below 500 ms. |
| Search responsiveness | p95 at or below 100 ms after a keystroke across 10,000 clips and 1,000 snippets, excluding background OCR. |
| Resource use | Idle CPU average below 1 percent over ten minutes. Steady resident memory below 150 MB with the standard fixture. |
| Reliability | No lost committed items across forced termination tests. No unexplained format loss in the supported application matrix. |

These are engineering targets, not measured results. Measure on an Apple Silicon Mac with 16 GB RAM and SSD storage, then repeat on Nino’s Mac Studio with three displays. Store fixture sizes and p50, p95 and worst-case results with each release.

## 2 Users and primary workflows

The initial audience is a Mac user who moves between writing, email, research and development. Typical content includes paragraphs, screenshots, web links, commands and repeated responses.

### Recover copied content

The user copies several items, opens devPaste, types a remembered word, checks the preview and presses Return. devPaste pastes into the application which held focus before the panel opened.

### Reuse a permanent snippet

The user switches to Quick Snippets, selects a named item and pastes it. Frequently used snippets have a direct shortcut. Saving a history item as a snippet creates an independent permanent copy.

### Move several items between applications

The user copies several values, arranges a paste queue and inserts them one at a time. A separate combined-paste action joins selected text items into one insertion with a visible separator choice.

## 3 Release scope and priorities

| Release | Required scope | Deferred scope |
| --- | --- | --- |
| V1 Mac foundation | Capture, search, previews, Quick Snippets, privacy, plain text, OCR, queue, combined paste, editing, standard transformations, export and import. | No cloud sync, mobile app, background website fetch, scripting engine, automatic expansion or AI integration. |
| V1.1 Workflow tools | Optional link metadata, deterministic rules, custom transformation chains, Shortcuts actions and controlled CLI. | No arbitrary shell execution from rules. No shared clipboards. |
| V2 Apple device sync | Optional iCloud sync, companion iPhone and iPad apps, explicit mobile capture routes, offline operation and conflict handling. | No promise of continuous background clipboard monitoring on iOS. |
| Future evaluation | Prompted templates, text expansion, shared collections and explicit AI or MCP access. | Requires a separate approved specification and privacy review. |

All V1 requirements in this document are required for the complete first release unless explicitly labelled later. Development milestones support incremental testing. They do not silently remove V1 functions.

## 4 Visual design and panel structure

UX01  Use the supplied reference image as a layout reference: a compact list on the left and a larger preview on the right. Recreate the useful arrangement rather than its promotional text, decorative glow or strong transparency.

UX02  Place a segmented control labelled Clipboard and Quick Snippets at the top. Keep search immediately underneath. Retain separate query, filter, selection and scroll state for each view during a session. Reopening clears the query by default and selects the first result in the last-used view. Offer a setting to retain the previous query.

UX03  Start with a panel approximately 940 by 600 logical points. Support resizing down to 620 by 400. Below 760 points wide, collapse the preview automatically and offer Space to open a preview overlay. Remember the user’s divider position.

UX04  Use a restrained native Mac appearance, system typography, light and dark modes, clear selection and strong contrast. Respect Reduce Transparency, Increase Contrast and Reduce Motion. Do not depend on colour to communicate type or status.

UX05  Show a footer with context-sensitive keyboard help, item count, capture pause state and queue progress. Keep destructive actions inside a menu or an explicit control rather than beside the main Paste action.

### Clipboard list and preview

Each row shows a type icon or thumbnail, a title or two-line text extract, source application and relative capture time. Link rows show the domain and address. The right pane shows full readable text, an image fitted to available space, a PDF preview where supported, or file metadata. Long content scrolls independently of the list. Display local time with an exact timestamp on request.

### Quick Snippets list and editor

Show snippet name, category, content type and shortcut where assigned. Offer All, Favourites and named categories. The preview contains the content and explicit Paste, Edit and Duplicate actions. The editor contains name, category, tags, content and optional shortcut. Keep a visible Save and Cancel path and protect unsaved edits on dismissal.

### Multi display behaviour

UX06  Open on the display containing the active application’s focused window. Fall back to the pointer display, then the main display. Use the last valid relative panel position on that display and clamp to its visible bounds. Validate focus detection during the engineering spike.

UX07  Dismiss on Escape or outside click unless Keep Open is selected. Do not dismiss while an editor has unsaved changes. Reconnect displays, change scaling and use full-screen Spaces without leaving an unreachable window.

## 5 Clipboard capture and history

CAP01  Monitor the general pasteboard change counter while capture is active. The initial implementation uses a lightweight adaptive poll with a target interval of 250 ms while active and a slower interval while idle. Stop unnecessary work during sleep. Reconcile the current clipboard on wake without importing repeated content.

CAP02  Capture complete pasteboard transactions containing one or several items. Preserve supported representations for each item: UTF-8 text, RTF, HTML, PNG, TIFF, PDF and file URLs. Treat unsupported formats as unavailable rather than converting them silently. Never execute copied content.

CAP03  Use a short stable snapshot and bounded retry if the pasteboard changes during reading. Preserve transaction boundaries. Continuous clipboard replacement faster than the polling interval is outside the guaranteed capture envelope. Record missed-read diagnostics without content.

CAP04  Record capture time, best-effort source bundle identifier, available format list, size and content hash. Source attribution is best effort. If uncertain, display Unknown rather than assigning the wrong application. Apply conservative exclusion handling during attribution races.

CAP05  Coalesce an exact repeated transaction by content hash, move it to the top and update last-copied time and copy count. Preserve materially different rich representations as distinct entries. Offer Keep duplicates for users who need a chronological record.

CAP06  Ignore devPaste’s own internal clipboard writes so pasting does not create an endless history loop. Use an internal transaction marker and an in-memory write fingerprint. Do not suppress a genuine later external copy of identical content.

CAP07  Default retention is 30 days with a maximum of 10,000 history transactions and a 1 GB history payload budget. Offer 1 day, 7 days, 30 days, 90 days and Until removed. Until removed remains subject to the visible capacity limits. Evict oldest unpinned history first and explain capacity cleanup.

CAP08  Limit one captured transaction to 50 MB of materialised payload and bound preview decoding separately. Skip oversized content with a non-intrusive status message. Do not truncate text and present it as complete. Reference-only file entries count metadata rather than external file size.

CAP09  History pinning protects selected items from normal expiry and oldest-first eviction. Pins still count toward storage. If protected content exhausts capacity, stop retaining new payloads and offer cleanup. Never remove Quick Snippets automatically to recover history space.

CAP10  Deleting history offers single-item, selected-item, last 5 minutes, last hour and clear-all actions. Clear-all explains whether pinned history is included. Quick Snippets require their own deletion action. Purge associated thumbnails, OCR and search records with the item.

## 6 Quick Snippets requirements

SNP01  Create snippets manually or through Save to Quick Snippets on a history item. Require a non-empty name. Suggest the first text line or filename. Duplicate names are allowed but displayed with category context.

SNP02  Support plain text, rich text, images and URLs. Store actual image and text payloads independently of the history entry. File snippets use an explicitly chosen managed copy or a reference with a clear dependency warning.

SNP03  Support categories, multiple tags, favourites, manual order and sorting by name, modification time or use frequency. Default to Favourites first, then manual order. Deleting a category moves its snippets to Uncategorised without deleting them.

SNP04  Editing a snippet creates a new saved revision. Retain the last ten revisions locally for recovery. Offer Duplicate and Restore previous version. Changes to a snippet do not rewrite its original history item.

SNP05  Assign optional global paste shortcuts to individual snippets. Detect conflicts with devPaste commands, duplicate assignments and registered system shortcuts where detection exists. Warn about undetectable application conflicts. Provide a single place to disable all snippet shortcuts.

SNP06  V1 inserts static content only. It does not monitor every keystroke for automatic abbreviation expansion. Prompted values, date variables and automatic text expansion belong to later scope.

## 7 Search filters and navigation

SRC01  Search locally across full text, snippet names, tags, OCR results, file names, URLs and source app names. Use case-insensitive matching with Unicode normalisation. Support multiple words as an AND query, exact quoted phrases and partial word matches where indexed.

SRC02  Offer labelled filters for All, Text, Images, Links and Files, plus source app and date range. Search the current view by default. Provide an explicit Search both views action with results labelled Clipboard or Quick Snippets.

SRC03  Rank exact name matches first in snippets, then prefix matches and content matches. History defaults to recency within matching results. Highlight matches without modifying stored content. Provide a clear reset action for combined search and filters.

SRC04  Index saved content asynchronously. Display newly captured entries immediately before indexing completes. Search results retain a stable selection during background OCR updates. Rebuild the derived index after corruption without losing source data.

SRC05  All essential actions work with keyboard navigation and VoiceOver. Expose selected state, type, source, timestamp and available actions. Use accessible names rather than relying on toolbar icons.

| Shortcut | Default behaviour |
| --- | --- |
| Command Shift V | Toggle the main panel. Detect registration failure and ask for an alternative. |
| Command 1 and Command 2 | Switch to Clipboard and Quick Snippets respectively. |
| Typing and Command F | Focus search and enter a query. Arrow keys navigate the results. |
| Return | Paste the selected item into the captured target application. |
| Option Return | Paste selected text as plain text. Disable for unsupported content. |
| Control 1 through Control 9 | Paste the corresponding visible numbered result. |
| Space | Toggle preview when the list has focus. Type a space normally in search or an editor. |
| Command S | Save selected clipboard item as a snippet. Save edits when an editor has focus. |
| Command E | Edit an eligible text item or snippet. |
| Escape | Close an overlay first, then the panel. Resolve unsaved edits before dismissal. |

All global shortcuts are configurable. Queue paste has no global default until the user selects an available shortcut. Application text-editing shortcuts retain their usual behaviour inside editors.

## 8 Paste engine and target handling

PST01  Capture the frontmost target application and focused context before opening the panel. On paste, write the selected representations, return focus to the captured target and request the normal paste action only after activation succeeds. Do not paste into devPaste itself.

PST02  Use explicit Accessibility permission for assisted direct paste. If permission is absent or revoked, retain capture and search, copy the selected item to the system clipboard and show Copied. Press Command V in your app. Do not claim the item was inserted.

PST03  Preserve original formats by default. Plain-text paste writes only the text representation. Per-application plain-text preferences are V1.1 rules. Disable transformations without a compatible representation.

PST04  If the original target closes, a secure field blocks insertion, focus changes unexpectedly or activation times out, stop automatic insertion and use copy-only fallback. Never redirect content to another application silently. A dispatched paste event is not proof the destination accepted it.

PST05  Do not simulate Return or Tab after a normal paste. Do not automatically submit forms, messages or terminal commands. Remote desktop and virtual machine support is best effort until explicitly tested and documented.

PST06  Leave the pasted content on the system clipboard by default. Do not restore the previous clipboard on a timer because applications read at different times. Mark internal writes to prevent recapture.

### Sequential paste queue

QUE01  Build an ordered queue from selected history items or snippets. Show sequence numbers, previews, reorder controls and Clear queue. Copy-to-queue mode is explicit and visibly active. Its default order is capture order, oldest first.

QUE02  Each queue shortcut writes and dispatches exactly one item. Advance only after target activation and paste-event dispatch. Display Insert requested rather than a guaranteed delivery claim. Retain a Previous item action to retry when the target rejects the event.

QUE03  Do not auto-submit or move between fields. Show queue progress in the menu bar and panel. Finish with Queue complete. Expire an inactive queue after ten minutes by default. Clear it on lock, quit or explicit cancellation.

### Combined paste

BAT01  Combine selected text items in visible selection order with newline, blank line, comma, tab or a custom separator. Show a preview and an order control before insertion. V1 combined output is plain text. Reject mixed image and text combinations with a clear explanation.

## 9 Editing transformations and OCR

TXT01  Offer a lightweight editor for plain text and URL content. History editing creates a derived entry and preserves the original. Snippet editing saves a revision. Rich-text editing uses a native editor and preserves supported formatting or requires an explicit conversion to plain text.

TXT02  V1 transformations include upper case, lower case, title case, trim outer whitespace, remove empty lines, normalise line endings and join wrapped PDF lines. Present before-and-after previews. PDF line joining is heuristic and never runs automatically.

TXT03  Transform a temporary working copy. Paste transformed content without overwriting the original. Offer Save as new snippet separately. Keep transformation behaviour deterministic, Unicode-aware and covered by examples.

OCR01  Use on-device text recognition on captured images in the background. Provide Extract text, Copy extracted text and Save extracted text as snippet. Store recognised text as derived searchable data and retain the original image.

OCR02  Begin with English recognition and expose supported language settings after platform validation. Bound OCR concurrency and downsample very large images for recognition. Show Pending, Ready, No text found or Failed. Retry manually and never invent missing words.

OCR03  Turning OCR off stops new recognition. Offer deletion of existing derived OCR text and index entries. Keep capture and paste available while recognition runs.

## 10 Files images and web links

FIL01  File history stores a security-scoped bookmark where available and display metadata. A reference is not a backup. If a file moves, is deleted or loses permission, show Unavailable and offer Locate. Never display a valid-looking preview from a broken reference without an unavailable label.

FIL02  Permanent file snippets offer Store a copy or Keep a reference. Store a copy imports a user-authorised file into managed storage with a visible size limit. V1 excludes folder snapshots and executable launching. File paste exports valid file URLs for the destination.

FIL03  Generate thumbnails asynchronously with bounded decoding and Quick Look where appropriate. A bad image or PDF must not crash the capture process. Never interpret file content as executable instructions.

WEB01  V1 shows the copied address, domain and any metadata already supplied by the source application. Do not fetch a website automatically. Opening a link uses the default browser after an explicit user action.

WEB02  V1.1 optional previews fetch metadata only after opt-in. Disable scripts, forms, credentials and automatic downloads. Block loopback, local-network and non-HTTP schemes, revalidate redirects and set response-size and timeout limits. Explain the destination site receives a request. Label cached previews with retrieval time. Do not present a preview as a safety or availability guarantee.

## 11 Privacy permissions and data protection

SEC01  First launch explains clipboard monitoring and starts capture only after the user chooses Start capture. Offer launch at login separately and default it off. Accessibility is requested when the user selects direct paste, not as a condition for browsing history.

SEC02  Skip clipboard types marked confidential, concealed, transient or auto-generated under supported conventions. Maintain a tested compatibility list. This detection is imperfect, especially for browser extensions. Provide explicit excluded-app settings and do not claim every secret is detected.

SEC03  Apply exclusions before storing payload, thumbnail, OCR, search text or logs. Provide app-based exclusions by bundle identifier. V1.1 adds explicit pattern rules. Avoid claiming reliable per-website exclusion from a browser without a separate integration.

SEC04  Provide Pause for 5 minutes, 15 minutes, 1 hour and Until resumed. Show a persistent paused indicator. Stop capture and clear the temporary queue while the screen is locked. Resume the previous capture state on unlock without importing the clipboard value copied during the locked interval.

SEC05  Offer Hide during screen sharing and recording, on by default. Validate supported system APIs and conferencing applications. If reliable detection is unavailable, label the limitation and supply a prominent Presentation mode which hides previews and pauses capture. Never promise universal screenshot protection.

SEC06  Encrypt persisted payloads, metadata, thumbnails, OCR text and search data at rest using a reviewed encrypted-store design. Keep the key in the macOS Keychain with device-only access appropriate to the deployment target. Do not ship a plaintext search index beside encrypted payloads. FileVault remains an additional protection rather than a substitute.

SEC07  V1 has no analytics, advertising SDKs, cloud account or content uploads. Diagnostics contain error codes, timings and counts only. User-initiated exports and later optional link requests are explicit exceptions. App updates must never include clipboard content.

SEC08  Deletion removes live records and derived data promptly. Encrypted database maintenance and backup rotation bound residual recovery. Do not advertise guaranteed forensic erasure from SSDs, system backups or previously exported files. Clear system clipboard is a separate explicit action.

SEC09  Locking the app conceals content immediately and cancels preview work. If the store key is unavailable, show a locked state and preserve encrypted data. Do not create a replacement empty store over existing data.

## 12 Settings onboarding and failure states

Settings contain General, Shortcuts, Capture and retention, Privacy, Appearance, Transformations and Data. Later versions add Rules, Automation and Sync. Include a searchable command menu rather than duplicating every action in the toolbar.

Onboarding has three short steps: explain capture and privacy, choose the panel shortcut, then try a sample copy and paste. Show optional Accessibility and login choices in context. Sample content is labelled and removable.

| State | Required response |
| --- | --- |
| Empty history | Explain Copy something to start. Offer a sample and a privacy-settings link. |
| No search results | Keep the query visible and offer Clear filters. |
| Capture paused | Show the resume time or Until resumed with a Resume control. |
| Storage full | Keep existing items readable. Explain which protected content blocks cleanup. |
| Permission denied | Use copy-only mode and provide a direct route to relevant system settings. |
| Store migration failure | Preserve the original files. Open recovery options and diagnostic export without content. |
| Corrupt preview or OCR | Keep the original clip available. Mark the derived operation failed and offer retry. |
| Unavailable referenced file | Show the original path as metadata and offer Locate or Remove reference. |

## 13 Proposed architecture

Use Swift with SwiftUI for the interface and AppKit for panel behaviour, focus management, pasteboard integration and native previews. Build a menu bar application with a separate settings window. Keep business logic outside view models so capture, search and paste receive independent tests. The minimum proposed deployment target is macOS 14, subject to an API and dependency spike.

| Component | Responsibility |
| --- | --- |
| Capture service | Observe clipboard changes, create stable snapshots, apply privacy policy, deduplicate and commit transactions. |
| Content repository | Own transactional records, encrypted payload files, retention, migrations, references and recovery. |
| Search service | Maintain encrypted derived indexes, execute filters and return ranked identifiers. |
| Paste coordinator | Track target context, authorise direct paste, write formats and coordinate queue state. |
| Snippet service | Own categories, revisions, favourites, shortcuts and history-to-snippet conversion. |
| Preview and OCR workers | Produce bounded asynchronous derivatives. Cancel work when hidden, locked or deleted. |
| Policy engine | Apply exclusions and capture state before persistence. Later evaluates explicit automation rules. |
| Presentation layer | Render the two views, editor, settings, accessible actions and menu bar status. |

Use structured concurrency and a single repository writer. Capture commits must not wait for thumbnails, OCR or website metadata. Publish committed identifiers to the interface, then schedule derived work. Cancellation checks prevent deleted items from reappearing after a worker finishes.

Proposed persistence is SQLite with full-text search inside an encrypted database, plus encrypted external blobs for large representations. Validate a maintained encryption library, licence, packaging and App Store compatibility before adoption. If the chosen library fails review, replace the storage design before implementing history. Do not weaken the encryption requirement silently.

Platform frameworks include AppKit, SwiftUI, Vision, Quick Look, Uniform Type Identifiers, Security and Service Management where supported. Use platform cryptography for blob encryption and Keychain for key handling. Pin third-party dependency versions and retain their licences.

## 14 Logical data model

| Entity | Key fields and relationships |
| --- | --- |
| Clip transaction | UUID, capturedAt, lastCopiedAt, sourceBundleID, sourceConfidence, contentHash, itemCount, byteSize, pinState, copyCount, pasteRequestCount. |
| Clip item | UUID, transactionID, ordinal, primaryType, displayTitle and optional file-reference identifier. |
| Representation | UUID, itemID or snippetRevisionID, UTI, encrypted payload reference, checksum, byteCount and storage policy. |
| Snippet | UUID, name, categoryID, tags, favourite, manualOrder, shortcut, currentRevisionID, createdAt and updatedAt. |
| Snippet revision | UUID, snippetID, revisionNumber, createdAt, format metadata and representation identifiers. |
| Derived content | OwnerID, thumbnail reference, recognised text, OCR state, language and derivation version. |
| Category | UUID, name, manualOrder. Each snippet has one category and zero or more tags. |
| File reference | UUID, bookmark, displayPath, lastKnownName, availability and managed-copy flag. |
| Paste queue | In-memory ordered owner identifiers and working snapshots, position and expiry. Never persist across quit. |
| Settings and policy | Schema version, retention, exclusions, shortcuts, visual preferences and feature flags. Protect sensitive patterns in the encrypted store. |

Persist dates in UTC and render locally. Use UUIDs as stable identifiers. Keep source payloads immutable for history and use derived entries for editing. Commit parent records and representations atomically. Garbage-collect unreferenced blobs after a successful commit and a recovery grace period. Use a shared content reference only when deletion and reference counting are transactional.

## 15 Backup import export and recovery

DAT01  V1 export supports selected snippets, all snippets or an explicitly selected history subset. Export is user initiated and shows the content scope. Default to an encrypted portable archive protected by a user-supplied passphrase with authenticated encryption and a reviewed key-derivation design. Do not export the device Keychain key.

DAT02  Offer plain JSON and text export only through an explicit unencrypted choice. Include a versioned manifest, relative attachment paths, checksums and representation types. Strip internal bookmarks and machine-specific credentials. Never include application logs or unrelated files.

DAT03  Import validates archive paths, declared sizes, checksums, schema and attachment types before writing. Reject traversal paths, oversized expansion and unsupported future schemas. Show counts and conflicts before commit. Default to importing as new snippets. Exact duplicate content offers Skip or Keep both.

DAT04  Create an encrypted local recovery snapshot before schema migrations and retain the last three successful snapshots. Explain these are on-device recovery copies. They do not protect against device loss. Export provides a separate portable backup route.

DAT05  On failure, roll back the migration and preserve original bytes. Support rebuilding previews and indexes from source content. Provide a recovery workflow for unavailable keys without claiming encrypted content is recoverable without its key or a portable backup.

## 16 Rules and automation for V1 1

RUL01  Rules have a name, trigger, conditions, ordered actions and an active flag. Evaluate capture exclusion before persistence. Other triggers include explicit paste or manual transform. Provide Test on sample and show the result without changing stored content.

RUL02  Conditions include source application, content type, size and bounded text patterns. Actions include Skip capture, Set retention, Add tag, Save a snippet copy and Apply transformation on explicit paste. Exclude and Stop takes precedence. Bound regular-expression work to prevent capture stalls.

RUL03  Do not run shell commands, arbitrary scripts, network calls or automatic paste as rule actions. Prevent rule loops with an origin identifier. Offer per-rule history using counts and outcomes without copied content.

AUT01  Shortcuts actions cover Search snippets, Get named snippet, Save text as snippet and Transform supplied text. Clipboard-history queries require an explicit user invocation and documented permission boundary.

AUT02  CLI access defaults off. After activation, support explicit snippet operations through a local authenticated channel. Do not expose unrestricted clipboard history, a network listener or a shell pipeline containing secrets by default. Define the command contract and consent model before implementation.

## 17 Apple device sync for V2

SYN01  Use an optional private iCloud container after the user opts in. Default to syncing Quick Snippets only. History sync requires a separate choice. Display account, sync scope, progress, last success, offline status and pause controls.

SYN02  Design a separate application encryption and key-sharing protocol before describing sync as end-to-end encrypted. Private iCloud storage alone is not sufficient proof of the application’s encryption claims. Establish recovery, new-device access and account-change behaviour during the V2 design gate.

SYN03  Use stable identifiers, server change tracking and tombstones. Preserve conflicting snippet edits as recoverable versions. Keep deletion tombstones for at least 90 days and require a full reconciliation for older offline devices. Do not resurrect expired history during reconciliation.

SYN04  On sign-out, stop synchronisation and ask whether local synced copies remain or are removed. Do not merge different iCloud accounts automatically. Local-only content stays separate from remotely managed deletion.

MOB01  Provide iPhone and iPad apps with snippets, history browsing, share-sheet capture and explicit clipboard import. A keyboard extension and Shortcuts actions are optional V2 work subject to platform constraints. Never promise continuous background capture on iOS.

MOB02  Store and search offline after initial sync. Respect mobile paste-access prompts. Keyboard extensions must not collect unrelated typing. Define any Full Access requirement before shipping the extension.

## 18 Distribution packaging and commercial decisions

Prepare a signed and notarised direct Mac build first for internal testing. Evaluate a sandboxed Mac App Store build during the initial spike, covering capture, Accessibility-based paste, shortcuts, file bookmarks, encrypted storage and login behaviour. Validate each channel independently. Do not assume identical permissions or update mechanisms.

The direct release needs signed updates and rollback planning. The App Store release uses store-managed updates. Both builds must use compatible data schemas and a documented migration route without running two capture services at once.

Working product name is devPaste. No public-name availability or trademark clearance has been performed. Pricing remains undecided. The preferred discussion starting point is a one-time Mac purchase with a clear major-upgrade policy. Sync operating costs and mobile licensing require a later decision. Do not inherit contradictory pricing claims from the supplied review.

## 19 Verification and release acceptance

Use unit tests for policy precedence, format round trips, deduplication, retention, transformations, archive validation and data migrations. Integration tests use an isolated pasteboard adapter and temporary encrypted stores. End-to-end tests cover real target applications and permissions. Never run automated paste tests against a user’s active documents or terminal.

| Test | Pass condition |
| --- | --- |
| AT01 Capture and duplication | Copy text, RTF, HTML, PNG, TIFF, PDF and multiple files. Supported representations survive capture. Identical transactions coalesce under the default setting. |
| AT02 Privacy | Confidential markers and excluded applications produce no payload, derivative, index entry or content log. Pause, lock and resume respect the capture boundary. |
| AT03 Direct paste | Paste into Word, Outlook, Notes, Safari, TextEdit and Xcode. Plain-text mode strips formatting. Permission denial and closed targets use copy-only fallback. |
| AT04 Target safety | Change focus, close the target and trigger a secure-input field. No unintended application receives an automated paste. No message or command is submitted. |
| AT05 Search and OCR | Find fixture text, names, URLs, source apps and known screenshot text. Filters and view boundaries behave as specified. OCR failure preserves the source image. |
| AT06 Snippets | Save from history, delete the history item and retain the snippet. Edit, recover a revision, move categories and verify shortcut conflicts. |
| AT07 Queue and combined paste | Reorder five values and dispatch one per action. Retry a rejected item. Combined output matches the chosen order and separator without submitting a form. |
| AT08 Storage and recovery | Force termination during capture, import and migration. Reopen without losing committed records. Inspect database, index, blobs and thumbnails for plaintext leakage. |
| AT09 Retention and capacity | Advance the test clock, exceed each limit and verify eviction order. Pins and snippets survive. Full protected storage stops new retention visibly. |
| AT10 Accessibility and displays | Complete capture retrieval and snippet insertion using keyboard and VoiceOver. Test three displays, disconnection, scaling, full-screen Spaces and contrast settings. |
| AT11 Performance | Meet section 1 targets with the fixed fixture. Capture during OCR and indexing remains responsive. Record thermal and memory conditions. |
| AT12 Import and export | Round-trip rich snippets and attachments. Wrong passphrase, corruption, traversal, archive expansion and schema mismatches fail safely without partial writes. |

Release gate: all V1 acceptance tests pass on the oldest supported macOS release and the current shipping release available at build time. No unresolved data-loss, privacy-boundary, unintended-paste or store-corruption defects remain. Document lesser known issues and supported file formats. Test current Word and Outlook builds explicitly because they form part of the primary workflow.

## 20 Delivery milestones and technical risks

| Milestone | Evidence required to progress |
| --- | --- |
| M0 Feasibility | Validate deployment target, sandbox and direct paste, source attribution, encrypted FTS, lock and sharing detection, file access and shortcut registration. Record limitations. |
| M1 Core panel | Working two-view panel, capture, encrypted repository, search, preview and direct paste with copy-only fallback. |
| M2 Reusable content | Snippet editor, categories, favourites, revisions, shortcuts, retention controls and import/export. |
| M3 Advanced V1 | OCR, queue, combined paste, transformations, multi-display handling and full privacy settings. |
| M4 Release candidate | Acceptance matrix, performance evidence, migration recovery, signing, onboarding and user help. |
| M5 Later releases | Begin V1.1 rules and automation or V2 sync only after their separate design gates pass. |

The main risks are paste events reaching an unintended target, incomplete secret detection, uncertain source attribution, file references becoming unavailable, encrypted search increasing implementation complexity and iOS capture limits. Address these with conservative fallbacks, explicit privacy controls, capability testing and a staged release scope.

Decisions still open are public branding, pricing, App Store timing, encryption dependency, final deployment target and whether website previews merit their network footprint. The proposed defaults elsewhere in this document stand unless engineering evidence requires a recorded change. Every scope change must update requirement IDs and acceptance coverage.

## 21 Reference material and provenance

The supplied image informed the list-and-preview arrangement. The conversation established the Clipboard and Quick Snippets switch, Mac-first scope, privacy priorities, transformations and a later sync release. The pasted reviewer description informed the comparison with Paste. It is opinion, not evidence of devPaste implementation or competitor pricing.

Official product material reviewed on 18 November 2026 provides feature context. Competitor availability and features change. These references are inspiration rather than a claim of feature parity or permission to copy their interface assets.

Paste App Store listing  https://apps.apple.com/gb/app/paste-limitless-clipboard/id967805235

Paste search and filters  https://pasteapp.io/help/search-and-filters

Paste capture and privacy behaviour  https://pasteapp.io/help/what-paste-captures

PastePal App Store listing  https://apps.apple.com/gb/app/clipboard-manager-pastepal/id1503446680

Pastebot official site  https://tapbots.com/pastebot/

Copy Em official site  https://apprywhere.com/ce-mac.html

Maccy official site  https://maccy.app/

Raycast clipboard manual  https://manual.raycast.com/clipboard-history

Alfred clipboard documentation  https://www.alfredapp.com/help/features/clipboard/
# devPaste
