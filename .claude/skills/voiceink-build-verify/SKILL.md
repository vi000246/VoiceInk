---
name: voiceink-build-verify
description: Safely verify that VoiceInk compiles and deploy the app WITHOUT creating ghost/duplicate "VoiceInk" icons in Launchpad/Spotlight. Use whenever building, compile-checking, or deploying VoiceInk (any xcodebuild / make build|local|deploy).
---

# VoiceInk: safe build verification & deploy

VoiceInk is a macOS `.app`. macOS **LaunchServices auto-registers every `.app` bundle it
sees on disk** — including build products. This creates the "two apps, one won't open" bug:

- A `xcodebuild ... build` into a `-derivedDataPath` under `/tmp`/scratchpad leaves a
  `VoiceInk.app` there. LaunchServices indexes it, so a **duplicate "VoiceInk" appears in
  Launchpad/Spotlight**.
- That duplicate **won't launch** because: (a) **Debug** builds split into
  `VoiceInk.debug.dylib` whose rpath/signature breaks the moment the bundle is launched from
  anywhere other than its original DerivedData (dyld "different Team IDs"); and (b) a copy in
  `/tmp` is unsigned → Gatekeeper blocks it.

## Rules — do this

1. **Never build a launchable `.app` into `/tmp`, the scratchpad, or any throwaway path.**
   If you must run `xcodebuild ... build` to check compilation, build into the repo's
   established `./.local-build` DerivedData (the same path `make local`/`make deploy` use) so
   no *new* ghost location is created:
   ```bash
   SWIFT_ENABLE_EXPLICIT_MODULES=NO xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk \
     -configuration Debug -derivedDataPath ./.local-build -xcconfig LocalBuild.xcconfig \
     CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual CODE_SIGNING_REQUIRED=NO \
     CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM="" \
     CODE_SIGN_ENTITLEMENTS="$(pwd)/VoiceInk/VoiceInk.local.entitlements" \
     SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) LOCAL_BUILD' build
   ```
2. **Prefer a compile check that produces no registerable app.** When you only need "does it
   compile", target the framework/library or use `build-for-testing` semantics rather than
   producing the full app bundle when practical.
3. **After any verification build, if a stray `.app` was produced outside `.local-build`,
   clean it immediately** (see snippet below). Don't leave it for LaunchServices to index.
4. **Only ever launch VoiceInk from `/Applications`.** Never open the `.app` from a build
   folder (`DerivedData`, `.local-build`, scratchpad).
5. **Piping `xcodebuild` to `tail`/`grep` hides the real exit code** (you get the pipe's).
   Redirect to a log file and grep it for `BUILD SUCCEEDED` / ` error: ` instead.

## Deploy (the ONLY step that should place a launchable app)

`make deploy` = Release (single binary, no debug-dylib split), signed with the stable
self-signed identity **"VoiceInk Local"**, installed to `/Applications` (replacing the old
copy), quarantine cleared, then launched. Stable signing keeps macOS permissions across
rebuilds.

```bash
make deploy   # needs the "VoiceInk Local" identity in the keychain
```

This is **system-touching** (`security find-identity`, `killall VoiceInk`, `rm -rf
/Applications/VoiceInk.app`, `ditto`, `codesign`, `open`). Confirm with the user before
running it, or have them run it themselves via `! make deploy`. It replaces the existing
`/Applications` copy, so it does **not** create a new duplicate.

Precheck the identity first: `security find-identity -p codesigning | grep "VoiceInk Local"`.

## Cleanup — if ghost/duplicate icons already exist

```bash
LSREG="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
# 1. Find every registered VoiceInk.app copy:
"$LSREG" -dump | grep -iE "path:.*VoiceInk\.app" | sort -u
# 2. Unregister + delete each stray build-folder copy (NOT /Applications):
"$LSREG" -u "/path/to/stray/VoiceInk.app"
rm -rf "/path/to/stray/VoiceInk.app"
# 3. Refresh Launchpad/Dock so the icon disappears:
killall Dock
# Heavy-handed fallback — rebuild the whole LaunchServices DB:
# "$LSREG" -kill -r -domain local -domain user -domain system
```

Keep exactly one launchable copy: `/Applications/VoiceInk.app`.
