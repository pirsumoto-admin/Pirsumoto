# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**Pirsumoto** is a Flutter mobile app for managing and listing used vehicles. It uses Firebase for auth/data, Riverpod for state management, and OpenAI (Whisper + GPT-4) for AI-assisted car listing via voice input.

**Target Platform**: Android only. All native configurations, permissions, background automation, and logic target Android exclusively. Disregard iOS and Swift.

## Common Commands

```bash
# Install dependencies
flutter pub get

# Code generation (Riverpod annotations, Freezed models) — run after modifying providers/models
flutter pub run build_runner build --delete-conflicting-outputs

# Watch mode for continuous code generation during development
flutter pub run build_runner watch

# Run the app
flutter run

# Lint & static analysis
flutter analyze

# Run tests
flutter test

# Run a single test file
flutter test test/widget_test.dart

# Platform builds
flutter build apk --release
./scripts/deploy_release.sh -l    # Build release APK, install on device, and launch
```

## Architecture

### Feature-based Structure

Code lives under `lib/features/`, organized by feature:
- `auth/` — Firebase Auth login screen and auth state provider
- `form/` — Multi-step car listing form (voice input → field extraction → image upload)
- `home/` — Bottom nav shell with 4 tabs
- `listings/` — List and detail views of user's car listings
- `profile/` — User profile management
- `settings/` — App settings

### Service Layer (`lib/services/`)

- `db_service.dart` — All Firestore operations. Listings stored at `users/{userId}/listings/{licenseNumber}`. Platform configs at `listingPlatforms` collection.
- `audio_service.dart` — Voice recording → OpenAI Whisper transcription (Hebrew) → GPT-4-turbo field extraction into structured car data.
- `webview_service.dart` — WebView management for external listing platforms.

### State Management

Uses **Riverpod 2** with code generation (`@riverpod` annotations). Run `build_runner` after modifying any `@riverpod`-annotated provider. Generated files have `.g.dart` suffix.

### Data Models

Immutable models via **Freezed**. Generated files have `.freezed.dart` suffix. The main form state is `CarFormState` in `lib/features/form/form_provider.dart`.

### Routing

`lib/routing/app_router.dart` — GoRouter with auth-based redirects: unauthenticated users go to `/login`, authenticated users go to `/home`.

### Localization

`easy_localization` with translation files in `assets/translations/he.json` (Hebrew) and `en.json` (English). Hebrew is the primary language.

### Theme

Dark Material 3 theme defined in `lib/shared/theme/app_theme.dart`. Primary: Indigo `#6366F1`, Secondary: Pink `#EC4899`, Surface: Slate 800 `#1E293B`.

## New Services

- `lib/services/vehicle_data_service.dart` — Static service calling the Israeli data.gov.il API to auto-fill maker/model/year/ownership/test from a license plate. Called from the license field search button in the form.

## Key Dependencies

| Package | Purpose |
|---|---|
| `flutter_riverpod` + `riverpod_annotation` | State management with code gen |
| `freezed` | Immutable data classes |
| `firebase_auth` + `cloud_firestore` + `firebase_storage` | Backend |
| `go_router` | Navigation |
| `easy_localization` | i18n (Hebrew/English) |
| `openai_dart` | Whisper STT + GPT-4 field extraction |
| `image_picker` | Image capture/selection for listings |
