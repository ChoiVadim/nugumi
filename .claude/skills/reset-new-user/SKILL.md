---
name: reset-new-user
description: >-
  Reset Gizmate (com.nugumi.app) on this Mac to a clean first-launch / new-user
  state so a reinstalled build behaves exactly like a fresh install. Use when
  asked to "reset Gizmate", "wipe local state", "test onboarding as a new user",
  "fresh install experience", "clear permissions and settings", or "сделай как у
  нового пользователя / сбрось приложение". Resets TCC permissions AND deletes
  all on-disk state — deleting the .app alone does NOT do this.
---

# Reset Gizmate to a new-user state

Make a reinstalled Gizmate behave like a brand-new install. The key fact:
**deleting the `.app` does NOT remove permissions or stored data.** TCC grants
and the data folders are keyed to the bundle ID `com.nugumi.app` (the build
pins its code requirement to `identifier "com.nugumi.app"`), so they survive
deletion and reinstall. They must be cleared explicitly.

The `nugumi` spelling below is not stale. The app was renamed to Gizmate, but
its bundle ID, defaults domain and support directory deliberately kept the old
name so existing users keep their permissions and credentials — see "Identity
that must not change" in `CLAUDE.md`. Reset the `nugumi` paths, not `gizmate`
ones, or the wipe silently misses everything.

## Before you run it

This is destructive and unrecoverable. It deletes:

- **API keys and OAuth tokens** (Codex / Claude Code subscription) — these are
  stored as plain files under `~/Library/Application Support/Nugumi/`, NOT the
  macOS Keychain (the type is misleadingly named `KeychainStore`). After the
  reset the user must sign in / re-enter keys again.
- All settings, onboarding flags, history, snippets, usage stats.

If the user might want to keep credentials, confirm before proceeding.

## Steps

1. **Quit any running Gizmate first** — otherwise it flushes its in-memory state
   back to disk on quit and undoes the wipe (this includes `swift run` dev
   builds). Older installs still run a binary named `Nugumi`, so kill both:

   ```sh
   for name in Gizmate Nugumi; do
     pgrep -x "$name" >/dev/null && kill "$(pgrep -x "$name")"
   done; sleep 1
   for name in Gizmate Nugumi; do
     pgrep -x "$name" >/dev/null && kill -9 "$(pgrep -x "$name")" || true
   done
   ```

2. **Reset permissions + delete all state** (run as one block):

   ```sh
   tccutil reset All com.nugumi.app          # Accessibility, Screen Recording, Microphone, Input Monitoring
   defaults delete com.nugumi.app 2>/dev/null || true
   rm -rf "$HOME/Library/Application Support/Nugumi"
   rm -rf "$HOME/Library/Caches/com.nugumi.app"
   rm -rf "$HOME/Library/Logs/Gizmate" "$HOME/Library/Logs/Nugumi"
   rm -rf "$HOME/Library/Saved Application State/com.nugumi.app.savedState"
   rm -rf "$HOME/Library/HTTPStorages/com.nugumi.app"
   rm -rf "$HOME/Library/WebKit/com.nugumi.app"
   rm -f  "$HOME/Library/Preferences/com.nugumi.app.plist"
   ```

3. **Verify it's clean:**

   ```sh
   tccutil reset All com.nugumi.app >/dev/null 2>&1; echo "TCC reset: $?"
   defaults read com.nugumi.app >/dev/null 2>&1 && echo "defaults STILL present" || echo "defaults: clean"
   for p in "Application Support/Nugumi" "Caches/com.nugumi.app" "Logs/Gizmate" "Logs/Nugumi" \
            "Saved Application State/com.nugumi.app.savedState" "Preferences/com.nugumi.app.plist"; do
     [ -e "$HOME/Library/$p" ] && echo "STILL EXISTS: $p" || echo "clean: $p"
   done
   pgrep -x Gizmate >/dev/null && echo "Gizmate STILL running" || echo "clean: no process"
   ```

## Notes

- A successful TCC reset prints `Successfully reset All approval status for com.nugumi.app`.
- A freshly downloaded DMG carries `com.apple.quarantine` — that's the real
  new-user Gatekeeper path. Because shipped builds are notarized + stapled, the
  first launch opens cleanly (no right-click → Open).
- If a stale "Gizmate" (or "Nugumi") entry lingers in System Settings → Privacy
  panes after the reset, it's from a `swift run` dev binary under a different
  code identity; remove it with the `−` button. It doesn't affect the downloaded
  `.app`.
- The downloaded build only contains features that have actually shipped in a
  release. To test unreleased local work as a new user, cut a release first,
  then run this reset before installing.
