#!/usr/bin/env node
// Turn a game.json + a built web bundle (in www/) into a Capacitor config.
// Usage: node scripts/prepare.mjs <path-to-game.json>
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";

const gameJsonPath = process.argv[2] ?? "game.json";
const g = JSON.parse(readFileSync(gameJsonPath, "utf-8"));

for (const req of ["slug", "name", "bundleId"]) {
  if (!g[req]) {
    console.error(`game.json missing required field: ${req}`);
    process.exit(1);
  }
}

const config = {
  appId: g.bundleId, // com.andusystems.games.<slug>
  appName: g.name,
  webDir: "www", // assets bundled OFFLINE — not a remote URL (App Store 4.2)
  bundledWebRuntime: false,
  plugins: {
    SplashScreen: { launchAutoHide: true },
  },
  // orientation is applied per-platform in the generated projects (android manifest / ios plist)
};

writeFileSync("capacitor.config.json", JSON.stringify(config, null, 2));

// Store metadata (fastlane supply/deliver read these). Generated per-game from game.json so the store
// listing is config, not hand-maintained. Screenshots/icons are added by the game's CI (or SpriteForge).
const full = g.description ?? `${g.name} — a game by andusystems.`;
const short = (g.shortDescription ?? g.name).slice(0, 80);
const write = (path, body) => {
  mkdirSync(path.slice(0, path.lastIndexOf("/")), { recursive: true });
  writeFileSync(path, body);
};
// Play (fastlane supply)
write("fastlane/metadata/android/en-US/title.txt", g.name.slice(0, 50));
write("fastlane/metadata/android/en-US/short_description.txt", short);
write("fastlane/metadata/android/en-US/full_description.txt", full);
// App Store (fastlane deliver)
write("fastlane/metadata/en-US/name.txt", g.name.slice(0, 30));
write("fastlane/metadata/en-US/subtitle.txt", short.slice(0, 30));
write("fastlane/metadata/en-US/description.txt", full);

console.log(`prepared shell for ${g.slug} (${g.bundleId}) orientation=${g.orientation ?? "default"} + store metadata`);
