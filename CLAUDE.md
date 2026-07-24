# Nugumi — Maintainer Instructions

This file is loaded as project context by Claude Code. It contains operational instructions that apply to every session working on Nugumi, not user-facing documentation.

## Project at a glance

- macOS menu bar app, Swift Package Manager, deployment target macOS 14.
- Bundle ID: `com.nugumi.app`. GitHub repo: `ChoiVadim/nugumi` (`origin`).
- GitHub CLI account for this repo: use `ChoiVadim`. If multiple accounts are configured locally, prefer `gh-vadim ...` or run `gh-use-vadim` before release/repo operations.
- Single source file: `Sources/Nugumi/App.swift` (everything except onboarding state lives here). `Sources/Nugumi/Bootstrap.swift` covers Ollama setup wizard.
- Distribution: ad-hoc signed `.app` + universal DMG packaged via `Scripts/build-app-bundle.sh`. In-app updates via Sparkle 2.9.1.
- Renamed from "Yaku" to "Nugumi" at v0.6.0. Existing v0.5.0 (Yaku) installs will not auto-migrate via Sparkle — they must download the new bundle manually from GitHub Releases. The Sparkle EdDSA key is unchanged across the rename.

## Cutting a release

The release flow is fully scripted. Do **not** run individual steps manually unless debugging.

```sh
# One-shot — bumps Info.plist, builds, signs, updates appcast, renames dmg.
export SPARKLE_BIN="$PWD/.build/artifacts/sparkle/Sparkle/bin"
bash Scripts/release.sh 0.6.0

# Then commit + tag + GitHub Release. Tag must be vX.Y.Z (the appcast item's
# enclosure URL is built as github.com/ChoiVadim/nugumi/releases/download/vX.Y.Z/Nugumi-X.Y.Z.dmg).
git add Resources/Info.plist appcast.xml
git commit -m "Release v0.6.0"
git tag v0.6.0 && git push origin main --tags
gh release create v0.6.0 dist/Nugumi-0.6.0.dmg --title "v0.6.0" --notes "Release notes here"
```

What `Scripts/release.sh` does, in order:

1. Bumps `CFBundleShortVersionString` to the supplied version and increments `CFBundleVersion`.
2. Runs `Scripts/build-app-bundle.sh` to produce `dist/Nugumi.app` and `dist/Nugumi.dmg` (universal arm64 + x86_64, ad-hoc signed, Sparkle.framework bundled and signed).
3. Signs the DMG via Sparkle's `sign_update` (uses the EdDSA private key in macOS Keychain).
4. Appends an `<item>` to `appcast.xml` with `sparkle:edSignature`, length, version metadata.
5. Renames `dist/Nugumi.dmg` → `dist/Nugumi-<version>.dmg` so the URL in the appcast matches the GitHub Release asset name.

After the GitHub Release is published, all installed copies of Nugumi will see the new version on their next daily Sparkle check (or immediately when the user clicks "Check for Updates...").

## Sparkle keys

- Public key is committed to `Resources/Info.plist` as `SUPublicEDKey`. **Never** rotate this casually — every shipped Nugumi (and prior Yaku) build has it baked in, and all updates must be signed with the matching private key.
- Private key lives in the maintainer's macOS Keychain (item name `https://sparkle-project.org`). It is **never** committed.
- If the private key is ever lost or compromised: generate a new pair (`./.build/artifacts/sparkle/Sparkle/bin/generate_keys`), update `SUPublicEDKey`, ship a new release manually (existing installs that haven't taken the rotation update will be stuck on the old key).

## Build script invariants

- `Scripts/build-app-bundle.sh` must remain idempotent. Running it twice should produce a clean `dist/Nugumi.app`.
- The script signs Sparkle's inner XPC services and helpers individually (Downloader.xpc, Installer.xpc, Autoupdate, Updater.app) before signing the framework wrapper, then signs the app bundle with `--options runtime`. Hardened runtime is **required** by Sparkle 2.x.
- The Sparkle framework must come from the universal `Sparkle.xcframework/macos-arm64_x86_64` slice. The script falls back to a generic `find` only if the universal slice is missing (e.g. host-arch only build).
- Designated requirement is pinned to `identifier "com.nugumi.app"` so accessibility/screen-recording permissions persist across rebuilds.

## Distribution signing modes

The build script picks the signing identity from `DEVELOPER_ID` env var. Three modes:

| Mode                     | Env vars                            | Outcome for end user                                                                                        |
| ------------------------ | ----------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| Ad-hoc (default)         | none                                | "unidentified developer" warning; right-click → Open required.                                              |
| Developer ID, no notary  | `DEVELOPER_ID`                      | Trusted by Gatekeeper but Apple notary check still pings online; first launch triggers a "verifying…" wait. |
| Developer ID + notarized | `DEVELOPER_ID` + `NOTARIZE_PROFILE` | Stapled ticket. Friend mounts DMG → drags to Applications → launches. Zero prompts, zero terminal.          |

### One-time setup for full notarization

1. Apple Developer Program enrollment ($99/yr): <https://developer.apple.com/programs/enroll/>.
2. Create a **Developer ID Application** certificate in Keychain Access (Xcode → Settings → Accounts → Manage Certificates). Note the full identity name, e.g. `Developer ID Application: Vadim Choi (XXXXXXXXXX)`.
3. Generate an app-specific password at <https://account.apple.com> → Sign-In and Security → App-Specific Passwords.
4. Store credentials in keychain so notarytool can read them non-interactively:
   ```sh
   xcrun notarytool store-credentials nugumi-notarize \
       --apple-id "tsoivadim97@gmail.com" \
       --team-id "XXXXXXXXXX" \
       --password "abcd-efgh-ijkl-mnop"
   ```
5. Save the env vars somewhere (a `.envrc`, shell rc file, or wrapper script — never committed):
   ```sh
   export DEVELOPER_ID='Developer ID Application: Vadim Choi (XXXXXXXXXX)'
   export NOTARIZE_PROFILE='nugumi-notarize'
   ```

### Per-release with full distribution

```sh
export SPARKLE_BIN="$PWD/.build/artifacts/sparkle/Sparkle/bin"
export DEVELOPER_ID='Developer ID Application: Vadim Choi (XXXXXXXXXX)'
export NOTARIZE_PROFILE='nugumi-notarize'
bash Scripts/release.sh 0.6.0
git add Resources/Info.plist appcast.xml
git commit -m "Release v0.6.0"
git tag v0.6.0 && git push origin main --tags
gh release create v0.6.0 dist/Nugumi-0.6.0.dmg --title "v0.6.0" --notes "..."
```

Notarization adds 2–5 minutes per release; `xcrun notarytool submit --wait` blocks until Apple finishes. The DMG is sent twice (once for the bundled `.app`, once for the DMG container itself) so Gatekeeper can verify offline at every stage.

### Sharing the build with users

Just send the GitHub Release URL: `https://github.com/ChoiVadim/nugumi/releases/latest`. Users click "Nugumi-X.Y.Z.dmg", mount, drag to Applications. Repeat for the link itself if convenient. After install, the in-app updater takes over.

## When editing App.swift

- Do not introduce a second source file unless an entire subsystem is being extracted. The single-file layout is intentional — easier to grep, easier to ship as a one-shot.
- `TranslationMode` declares per-mode metadata (`resultLabel`, `loadingPlaceholder`, `systemPrompt`). New modes go through this enum, not via callsite branching.
- `OllamaModelOption.all` is the source of truth for which models the menu offers. Update it when adding model variants — do not hardcode model IDs in `OllamaClient` or `OllamaBootstrap`.
- The floating button uses a single `NSButton` whose `title` and `image` swap based on `TranslationMode`. Don't reintroduce overlapping `NSTextField` / `NSImageView` views — they break centering.
- For permissions (Accessibility, Screen Recording), prefer requesting at startup in `applicationDidFinishLaunching`. Don't add silent failure paths.

## App icon

`Resources/AppIcon.icns` is generated from `Scripts/generate-icon.swift`. Regenerate after editing the renderer:

```sh
swift Scripts/generate-icon.swift Resources/AppIcon.icns
```

The README header logo at `docs/screenshots/logo.png` is extracted from the `.icns` (256×256@2x slice). After regenerating the icon, re-extract:

```sh
iconutil --convert iconset Resources/AppIcon.icns -o /tmp/AppIcon.iconset
cp /tmp/AppIcon.iconset/icon_256x256@2x.png docs/screenshots/logo.png
```

## Local development

```sh
swift run Nugumi                  # debug build, no .app bundle, Sparkle inert.
bash Scripts/build-app-bundle.sh  # full universal release bundle + DMG.
```

In `swift run` mode Sparkle is fully inert: `updaterController` is `nil` and the "Check for Updates..." menu item is hidden. Sparkle requires a real `.app` bundle (Frameworks/Sparkle.framework + hardened runtime + Info.plist), so end-to-end update testing must use `bash Scripts/build-app-bundle.sh` and run `dist/Nugumi.app`.

## Restart the app after changes (use `swift run Nugumi`)

After any code change the user wants to see, restart the app — otherwise the user is looking at stale UI. **For testing, use `swift run Nugumi`, not a full bundle rebuild.** Kill the previous instance first and relaunch:

```sh
pkill -f 'Nugumi' ; swift run Nugumi   # quick debug run — this is the default test step
```

- `swift run Nugumi` is the fast dev loop for UI/behavior iteration (a debug build, Sparkle inert). Do NOT run `bash Scripts/build-app-bundle.sh` just to see a change — that full universal signed bundle is only for release, Sparkle/update testing, or when a feature needs TCC permissions correctly attributed to `com.nugumi.app` rather than the shell (the "TCC launch trap").
- Run it in the background so it doesn't block, and re-run (kill + `swift run`) after each subsequent change.
