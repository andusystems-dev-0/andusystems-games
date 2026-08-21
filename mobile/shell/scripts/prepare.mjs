#!/usr/bin/env node
// Turn a game.json + a built web bundle (in www/) into a Capacitor config.
// Usage: node scripts/prepare.mjs <path-to-game.json>
import { readFileSync, writeFileSync } from "node:fs";

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
console.log(`prepared shell for ${g.slug} (${g.bundleId}) orientation=${g.orientation ?? "default"}`);
