# Mobile release — one web bundle, thin store wrapper

The game is a **web bundle**. The App Store / Play Store apps are a **generic Capacitor shell**
that bundles that exact web build **offline** and renders it (D-011/D-012). No per-game native
code, no separate game development. The shell + the packaging workflow live in **this public repo**
so public game repos can call them without private-repo access.

## Why a wrapper (not a webview of a URL)
Apple **Guideline 4.2** ("minimum functionality") rejects apps that are just a website. We avoid
that by:
- **Bundling assets offline** (`webDir` = the built bundle) — the app works with no network.
- **Native save** via the SDK over Capacitor Preferences/Filesystem (source of truth), with
  background sync — a real, self-contained game, not a remote page.
- Native niceties (haptics, status bar, orientation lock, splash) via Capacitor plugins.
A remote-URL webview would risk 4.2 rejection and require connectivity — don't do it.

## The shared shell
`mobile/shell/` (in this repo): one Capacitor app parameterized by the game's `game.json`
(slug, display name, bundle id `com.andusystems.games.<slug>`, icons, splash, orientation). CI
copies the game's web build into `webDir`, injects metadata, and regenerates the Android/iOS
projects fresh each run — nothing native is committed per game.

## Reusable packaging workflow
`.github/workflows/mobile-package.yml` (`workflow_call`), invoked by each game's CI:
```
inputs: { slug, web_artifact, track }   # track: 'beta' (uat) | 'release' (prod)
steps:
  - fetch web_artifact + game.json
  - npx cap add/sync into mobile/shell
  - Android: ./gradlew bundleRelease  → signed .aab   (Play App Signing)
  - iOS:     xcodebuild archive/export → signed .ipa   (needs macOS runner — CONFIRM)
  - fastlane <lane>                    # supply / pilot+deliver
secrets (from org/GH): PLAY_SERVICE_ACCOUNT_JSON, APPLE_API_KEY_P8, APP_STORE_CONNECT_*, signing certs
```

## Fastlane lanes
- `beta` → **TestFlight** + Play **internal testing** (= UAT).
- `release` → **App Store** + Play **production** (= prod).
Same `.aab`/`.ipa` promoted beta→release; no rebuild (D-012).

## Signing
- **Android:** Play App Signing (Google holds the app key); CI signs the upload key.
- **iOS:** `match` (git-stored certs/profiles) or manual signing; needs an Apple Developer account.
- **macOS runner** for iOS builds: the estate has none today (CONFIRM) — options: a Mac mini on the
  LAN as a self-hosted runner, or a hosted macOS runner. Blocks **iOS only**; Android ships without it.

## Accounts / prerequisites (the operator)
- **Apple Developer Program** ($99/yr) + App Store Connect app records per game.
- **Google Play Developer** ($25 one-time) + a service account JSON for API upload.
- Bundle ids `com.andusystems.games.<slug>` reserved on both stores.

## Payments on mobile (hard rule)
Do **not** put a Stripe purchase flow in the app for digital goods (App Store **3.1.1** / Play
Billing). The app reads **entitlements** (bought on the web) and unlocks content. See `payments.md`
for the compliant web-first model and the later options (external-link entitlement / native IAP).
