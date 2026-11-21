# 0004 Xcode project and Swift package side by side

Date: 20 November 2026. Status: accepted (revised the same day). Lite record (Personal).

- **Decision.** `devPaste.xcodeproj` is the main way to build, run and test. It uses folder-synced groups, so it lists no files. `Package.swift` with `build.sh` and `smoke.sh` stays for the one-command smoke test and installing from the terminal.
- **Why.** Nino asked for an Xcode project. The package keeps principle 8's single-command smoke test.
- **Principle affected.** Principle 6, one source of truth: two build descriptions. Kept small because both point at the same `Sources/` and `Tests/` folders and neither lists files.
- **Reversal point.** If the two drift (a new target in one but not the other), drop the package and run the smoke test with `xcodebuild`.
