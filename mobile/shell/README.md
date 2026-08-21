# mobile/shell — the shared Capacitor wrapper

One **generic, offline** Capacitor app that renders *any* game's web bundle. There is **no per-game
native code** (D-011). CI copies a game's built web bundle into `www/`, injects its `game.json`
(app id/name/icons/splash/orientation), regenerates the Android/iOS projects, and builds signed
artifacts. See `../../docs/mobile-release.md`.

## How it's used (by the reusable workflow, not by hand)
`.github/workflows/mobile-package.yml` does:
1. download the game's web artifact → `www/`
2. `node scripts/prepare.mjs <path-to-game.json>` → writes `capacitor.config.json` (appId, appName, orientation) and stages icons/splash
3. `npx cap sync` → regenerate `android/` + `ios/` fresh
4. Android `./gradlew bundleRelease` → signed `.aab`; iOS `xcodebuild` → signed `.ipa` (macOS runner)
5. `fastlane <lane>` → TestFlight/Play-internal (beta) or App Store/Play production (release)

## Offline, not a remote webview
`webDir = www` with the assets **bundled** — the app runs with no network (clears App Store 4.2).
Saves go through the SDK over Capacitor Preferences/Filesystem. Never point `server.url` at a remote
site for digital-goods apps.

Nothing here is committed per game; the projects are regenerated each run.
