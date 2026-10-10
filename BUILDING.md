# Building Free Flow

Requirements: macOS 26, Apple Silicon, Xcode 26.

1. Build whisper.cpp as an xcframework and place it at `Vendor/whisper.xcframework`.
2. Create `scripts/local.env` with your Developer ID signing identity:
   ```sh
   export PARLE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
   export PARLE_TEAM=TEAMID
   export PARLE_NOTARY_PROFILE=your-notarytool-profile
   ```
3. Build:
   - `scripts/build-freeflow.sh`: Release build to `~/Applications`.
   - `scripts/ship-freeflow.sh`: build, smoke test, swap in, relaunch (rolls back on crash).
   - `PARLE_TIMESTAMP=1 PARLE_BUILD=<n> scripts/ship-freeflow.sh`: same, plus a notarized DMG in `.local-build/dist/<version>/`.

Swift packages built from source live in `Packages/`.
