# waec_app

WAEC results verification and retrieval platform - mobile client

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.

## Regenerating brand assets (icon & splash)

The launcher icon and splash screen are produced by a reproducible pipeline so
native resources never drift from the brand again.

1. **Single source of truth:** `assets/brand_kit.json` — app name, tagline,
   splash description/statuses, colors, fonts, organization/support contacts,
   compliance badges and copyright all live here. The About screen and the
   branded splash read it via `lib/core/brand.dart`, and the asset generator
   below reads the same file, so native assets and UI always agree.
2. **Logo source:** `docs/waec_direct_logo-new.png` — a navy/mint glyph on a
   **transparent** canvas. Icon and splash use a **white background**.
3. **Clean masters** (ffmpeg + Lanczos, no ImageMagick):

   ```bash
   bash ../../scripts/gen_brand_assets.sh
   ```

   Produces in `assets/brand/`:
   - `logo_mark.png` — transparent glyph (used by the in-app splash).
   - `icon_master.png` — white square + glyph (legacy launcher + iOS).
   - `adaptive_foreground.png` — transparent glyph at ~66% safe zone.
   - `android12_icon.png` — **glyph only** at ~62%: Android 12+ scales and
     masks the splash icon into a circle, so a wordmark there gets cut off.
   - `splash_logo.png` — white pre-12 splash composition (glyph + name +
     tagline + description + progress bar + status).
4. **Generate native resources** (after `flutter pub get`):

   ```bash
   dart run flutter_native_splash:create
   dart run flutter_launcher_icons
   ```

5. **iOS icons** (the source script is correct; compiling requires macOS/Xcode):
   `bash ../../scripts/gen_ios_icons.sh`.

> `assets/logo.png` / `assets/splash.png` are kept bundled but unused; the
> pipeline masters live in `assets/brand/`.

### Splash flow

Native splash (static brand bitmap) → `FlutterNativeSplash.preserve` keeps it
until the in-app `BrandedSplash` paints → `BrandedSplash` shows the logo,
description, a **live** progress bar and rotating status messages from the brand
kit, then hands off to the auth gate via `FlutterNativeSplash.remove()`.

### Physical-device verification (debug)

Launcher-icon caches and Gradle resource caching mask changes, so after any brand
update run `flutter clean`, **uninstall** `gh.com.waecplatform.waecdirect` from
the phone, then `flutter pub get`, re-run the two generators, and
`flutter run --debug`. Confirm: clean white adaptive launcher icon with the
navy/mint glyph, branded white cold-start splash, no color flash, and
(Android 12+) a branded white SplashScreen API screen.
