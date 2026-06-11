---
name: run-bks-baseball
description: Run, build, launch, screenshot, and interact with the BKS Baseball iOS app in the Simulator. Use when asked to run the app, start the simulator, take a screenshot, verify a UI change, or confirm the board is loading correctly.
---

# BKS Baseball iOS — Run Skill

The app is a SwiftUI / MVI iOS app driven via the iOS Simulator. Interaction is handled by `.claude/skills/run-bks-baseball/driver.swift` — a compiled Swift script that posts CoreGraphics touch events and wraps `xcrun simctl`.

The driver is run with `swift .claude/skills/run-bks-baseball/driver.swift <command>` from the repo root.

## Prerequisites

- Xcode 16+ with `xcrun simctl` on PATH (standard macOS dev machine)
- iPhone 17 Pro simulator booted (UDID `696C988E-E778-474C-BE5B-023EEFF8B45F`)
- Firebase App Check debug token in `App/Config/Debug.xcconfig` as `FIRA_APP_CHECK_DEBUG_TOKEN`

No `apt-get` installs required — macOS native toolchain only.

## Build

```bash
xcodebuild \
  -project App/BKSBaseball.xcodeproj \
  -scheme BKSBaseball \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,id=696C988E-E778-474C-BE5B-023EEFF8B45F' \
  -derivedDataPath /tmp/bks-dd \
  build 2>&1 | grep -E "error:|warning:|BUILD " | grep -v appintentsmetadataprocessor
```

Or via driver:

```bash
swift .claude/skills/run-bks-baseball/driver.swift build
```

Build succeeds in ~60s on a warm DerivedData cache, ~3min cold.

## Run (agent path)

### Step 1 — Boot simulator

```bash
swift .claude/skills/run-bks-baseball/driver.swift boot
# or: xcrun simctl boot 696C988E-E778-474C-BE5B-023EEFF8B45F
```

### Step 2 — Install built app

```bash
xcrun simctl install 696C988E-E778-474C-BE5B-023EEFF8B45F \
  /tmp/bks-dd/Build/Products/Debug-iphonesimulator/BKSBaseball.app
```

### Step 3 — Launch with Firebase App Check token

```bash
SIMCTL_CHILD_FIRAAppCheckDebugToken=2CF93C60-C363-4A79-9BA7-130EEBD5E3BF \
  xcrun simctl launch 696C988E-E778-474C-BE5B-023EEFF8B45F com.blackkatt.bksbaseball
sleep 6
```

**The `SIMCTL_CHILD_` prefix is mandatory.** Without it, Firebase App Check rejects all API calls silently, auth validation fails, and the app loops on the sign-in screen.

### Step 4 — Take a screenshot

```bash
swift .claude/skills/run-bks-baseball/driver.swift ss /tmp/bks-check.png
# Opens: open /tmp/bks-check.png
```

### Driver command reference

```bash
swift .claude/skills/run-bks-baseball/driver.swift <command>

  boot               Boot the simulator device
  build              xcodebuild to /tmp/bks-dd
  install            Install from /tmp/bks-dd to simulator
  launch             Launch with App Check token (sleep 6 after)
  terminate          Kill running app
  ss [path]          Screenshot (default /tmp/bks-ss.png)
  screenshot [path]  Alias
  tap <sx> <sy>      Click at absolute screen coordinates (use 'window' to orient)
  tap-dev <dx> <dy>  Click at device logical coords (0-393 x, 0-852 y)
  window             Print current Simulator window bounds on screen
  board              Launch + dismiss privacy notice → board visible
```

### Tapping / interacting

The driver posts CoreGraphics mouse events to the Simulator window. **This requires no Accessibility permissions** — it uses `CGEventPost(.cghidEventTap)` which works in non-interactive (remote/headless) sessions.

Get the Simulator window's current screen position first:

```bash
swift .claude/skills/run-bks-baseball/driver.swift window
# → Simulator window: x=1649.0 y=1149.0 w=440.0 h=940.0
```

Then tap using device logical coordinates (0-393 horizontal, 0-852 vertical):

```bash
swift .claude/skills/run-bks-baseball/driver.swift tap-dev 196 600
```

Or absolute screen coordinates (using the `window` output):

```bash
swift .claude/skills/run-bks-baseball/driver.swift tap 1869 1800
```

## Run (human path)

Open `BKSBaseball.xcworkspace` in Xcode, select the iPhone 17 Pro simulator, hit ⌘R. The Xcode scheme passes `FIRAAppCheckDebugToken` automatically via the `FIRA_APP_CHECK_DEBUG_TOKEN` xcconfig variable.

## Test

```bash
xcodebuild test \
  -project App/BKSBaseball.xcodeproj \
  -scheme BKSBaseball \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,id=696C988E-E778-474C-BE5B-023EEFF8B45F' \
  2>&1 | grep -E "Test Suite|passed|failed|error:" | grep -v "appintentsmetadataprocessor|Firebase|APM"
```

Note: The test target has a **pre-existing linker failure** against BKSCore's test binary in a fresh DerivedData. Build the app target first (`swift driver.swift build`) before running tests — the shared DerivedData warms the linker.

## Gotchas

**`SIMCTL_CHILD_` prefix is the only way to pass env vars to simctl.**  
`xcrun simctl launch --env KEY=VALUE` returns `Invalid device: --env` on Xcode 16. The correct form is `SIMCTL_CHILD_KEY=value xcrun simctl launch ...`.

**Without `FIRAAppCheckDebugToken`, auth silently breaks.**  
Firebase App Check blocks all API calls. The app shows the email sign-in form with autofilled credentials but the credentials fail every time. There's no error banner — it just loops. Pass the debug token.

**The Simulator window is frameless — chrome = 0.**  
`CGWindowList` reports the window bounds including the device bezel drawn by Simulator. The tap mapping treats the full window as the device screen: `screenX = winX + (devX/393)*winW`. Using a chrome offset (52px, 70px) sends taps to wrong positions.

**`CGEvent` taps work without Accessibility permissions in non-interactive sessions.**  
`AXUIElement` and `System Events` both fail with `kAXErrorAPIDisabled` / `-1719` in remote sessions. `CGEventPost(.cghidEventTap)` works reliably as long as the event coordinates land within a visible window.

**The first-launch privacy notice blocks the board.**  
Only appears once per app install. Tap at device coordinates (196, 600) to dismiss "Continue". The `board` driver command handles this automatically.

**The board requires a valid stored credential in the simulator keychain.**  
Auth credential is persisted via `StoredCredential` in the simulator keychain (`auth.credential` key). On a fresh simulator (first install), the user must complete sign-in once before the board loads automatically on relaunch. On subsequent launches, the credential is re-validated against Firebase on app start.

**Hardware keyboard Return key does NOT reach the Simulator in a non-interactive session.**  
`CGEvent` keypresses via `.cghidEventTap` or `.postToPid` don't reach iOS app text fields in remote sessions. The email/password form submits via `onEditingEnded` when both fields have text — focus the password field by tapping it, then trigger via the on-screen Return key (visible only when software keyboard is shown).

**Test linker fails after DerivedData nuke on BKSCore.**  
Pre-existing issue. Build the app target first to warm up BKSCore, then run tests.

## Troubleshooting

**`Invalid device: --env`** — You used `simctl launch --env`. Use `SIMCTL_CHILD_KEY=value` prefix instead.

**App shows "Sign In Failed - The email or password is incorrect"** — The keychain credential is invalid or the App Check token wasn't passed. Re-launch with `SIMCTL_CHILD_FIRAAppCheckDebugToken`.

**`Unrecognized subcommand: touch`** — `simctl io tap` is not available. Use the driver's `tap` or `tap-dev` commands instead.

**Simulator window not found by driver** — The Simulator app isn't running or the window is minimized. Run `open -a Simulator` first, then `xcrun simctl boot 696C988E-E778-474C-BE5B-023EEFF8B45F`.

**Taps land in wrong place** — The Simulator zoom level changed. Run `swift driver.swift window` to get current bounds and recalculate. The frameless mapping `devX → winX + (devX/393)*winW` should hold at any zoom.

**Build fails: "Build input file cannot be found: DraftKingsMLBCalculator.swift"** — A deleted file is still referenced in the Xcode project. Remove its 3 entries from `App/BKSBaseball.xcodeproj/project.pbxproj` (PBXBuildFile, PBXFileReference, PBXGroup child) and rebuild.
