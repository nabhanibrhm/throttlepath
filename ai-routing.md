# AI model routing

> **AI AGENT INSTRUCTION:** Whenever a new change request is received, you must first read this file, identify the target files for the request, and switch to the cheapest approved model listed below before writing any code.

ThrottlePath is a Flutter app whose whole value is a ride record that is *correct*. Almost
nothing here is a web request that can be retried — a mis-handled GPS blackout silently
writes a wrong distance into a row the rider keeps forever, and the ride that produced it
cannot be ridden again. The tiers below are weighted for that: anything that can change a
stored number, or the rules that derive one, routes high regardless of how small the diff is.

## Models and effort

| Model | Effort | Use for |
|---|---|---|
| **Haiku 5.5** | default | Docs, comments, palettes and theming, static config, new cases for pure formatting helpers |
| **Sonnet 5.5** · medium | medium | One widget or one screen, a chart, a pure helper in `core/`, a `tool/` diagnostic |
| **Sonnet 5.5** · high | high | A service plus its provider plus the screen that reads it, export writers, the share pipeline, anything spanning three or more files |
| **Opus 5.5** · high | high | The GPS write path, the read path, the Isar schema, the Android host, lean / smoothness / clock maths, anything that writes to a real device DB |
| **Opus 5.5** · max | xhigh / max | Architecture refactors, a wrong-telemetry bug with no known cause, a migration over existing ride data, re-deriving stored aggregates |

**How to switch.**
- **Session:** if the current model or effort is higher than needed, say so in one line and ask the user to switch with `/model`. If it's lower, stop and ask for the higher one before writing code.
- **Subagents:** set `model` (`haiku`, `sonnet` or `opus`) and `effort` on the agent call to match the table. Delegating cheap work this way is preferred over switching the whole session.

---

## Routing map

Paths are relative to the repo root. Where several rows match a file, the first one wins.

### Opus 5.5

| Path / pattern | Effort | Why |
|---|---|---|
| `lib/services/tracking_service.dart` | high | The write path. Long-gap re-anchor, signal-loss auto-pause, accuracy-reject streak, impossible-jump gate — the guards that keep a phantom 33 km out of a stored total. |
| `lib/core/track_runs.dart` | high | The read path, and the home of `kSignalLossSeconds`. Every consumer segments through this one module; if it and the engine disagree, the read path silently re-bridges what the engine refused to count. |
| `lib/core/ride_clock.dart`, `lib/core/gps_kalman.dart` | high | Elapsed time and position smoothing. A clock bug corrupts a ride in progress. |
| `lib/core/lean.dart`, `lib/core/smoothness.dart` | high | Derived telemetry with its own guards (smooth-arc, 3-sample corroboration). A loosened guard brings the train artifact back. |
| `lib/core/units.dart` | high | The metric-storage contract. Everything is stored and computed in metric; a conversion that leaks into the write path rewrites history. |
| `lib/core/route_key.dart`, `lib/core/route_blob.dart` | high | Ride identity and the stored route. Feeds dedup and the "continue a nearby trip?" nudge. |
| `lib/data/models/*.dart` (Isar schema), `lib/data/database_service.dart` | high | A schema change migrates a 25 MB DB of real rides. See **Generated** below before touching a model. |
| `lib/services/ride_recovery.dart` | high | Recovers an interrupted ride. Its failure mode is losing one. |
| `android/app/src/main/kotlin/**` (`MainActivity.kt`, `PipController.kt`, `GnssStatusStreamer.kt`) | high | Foreground service, PiP and the GNSS stream — where background tracking actually survives lock/sleep. |
| `android/app/src/main/AndroidManifest.xml`, `android/**/*.gradle.kts`, `android/gradle.properties` | high | Carries baked-in build fixes (`kotlin.incremental=false`, `tools:replace="android:exported"`) that must not be "cleaned up". |
| `test/track_runs_test.dart`, `ride_clock_test.dart`, `lean_test.dart`, `gps_kalman_test.dart`, `ride_analysis_test.dart` | high | The guard tests. Changing an expectation here is changing the contract. |
| Any script or task that writes to a pulled or on-device DB | high | `tool/` reads are Sonnet; a write is not. |
| A wrong distance / duration / speed / lean with no known cause | max | |
| Re-deriving stored aggregates, or any migration over existing rides | max | |

### Sonnet 5.5 · high

| Path / pattern |
|---|
| `lib/providers/**` — `tracking_providers`, `home_providers`, `history_providers`, `stats_providers`, `pip_providers`, `settings_providers` |
| `lib/services/` `ride_share.dart`, `share_basemap.dart`, `share_channel.dart`, `widget_to_image.dart` (the export pipeline — the PNG must match the preview) |
| `lib/services/` `gpx_export.dart`, `rides_csv_export.dart`, `route_derivation.dart`, `geocode_backfill.dart`, `geocoding_service.dart` |
| `lib/services/` `location_source.dart`, `gnss_status.dart`, `permission_service.dart`, `pip_service.dart`, `tile_cache_service.dart` |
| `lib/data/ride_stats.dart`, `lib/data/trip_stats.dart` |
| `lib/ui/tracking_map_screen.dart`, `ride_detail_screen.dart`, `trip_detail_screen.dart`, `ride_summary_screen.dart`, `home_shell.dart`, `splash_screen.dart` (startup init lives in the splash, not `main()`) |
| `lib/ui/share_card.dart`, `share_flow.dart`, `pip_host.dart` |
| `lib/main.dart` |
| `pubspec.yaml` (a version bump alone is Haiku; a dependency change is not) |
| `scripts/build-release.ps1`, `scripts/deploy-debug.ps1` |

### Sonnet 5.5 · medium

| Path / pattern |
|---|
| Pure helpers in `lib/core/`: `geo.dart`, `date_format.dart`, `duration_format.dart`, `ttff.dart`, `record_view.dart`, `speed_gauge_style.dart` |
| Charts: `lib/ui/` `elevation_speed_chart`, `lean_chart`, `live_speed_chart`, `smoothness_chart`, `speed_distance_chart`, `speed_zone_chart`, `chart_frame`, `chart_math`, `route_sparkline`, `speed_sparkline` |
| Single screens and their widgets: `history_screen`, `settings_screen`, `week_strip`, `ride_controls`, `ride_display_switcher`, `telemetry_sheet`, `status_pills`, `acquiring_progress`, `place_route_label`, `no_track_notice`, `rename_dialog`, `theme_picker_sheet`, `detail_app_bar`, `route_map_view`, `record_backdrops`, `live_speed_announcer` |
| Gauges: `analog_speed_gauge.dart`, `lean_gauge.dart`, `pip_card.dart` |
| `lib/services/settings_service.dart` (a new flag; a change to what a flag *gates* follows that code's row) |
| `tool/` diagnostics — `dump_ride.dart`, `dump_trip.dart`, `kalman_step.dart`, `lean_probe.dart` (read-only by contract; kept out of the app build, don't wire them in) |
| Tests for anything in this tier |

### Haiku 5.5

| Path / pattern |
|---|
| `**/*.md` — `README`, `CLAUDE.md`, this file |
| `lib/theme/app_theme.dart`, `lib/core/speed_palette.dart`, `lib/ui/lean_palette.dart`, `lib/ui/hairline_row.dart` (a palette **threshold** or a speed **band** follows the maths it comes from) |
| `analysis_options.yaml`, dotfiles, `.gitignore`, launcher-icon config in `pubspec.yaml` |
| A `pubspec.yaml` version bump on its own |
| New cases in `test/` for pure formatting helpers — `duration_format_test`, `contrast_test`, `geocoding_label_test` (changing an expected **distance, speed or lean** is Opus) |
| `graphify-out/**` (reference only — regenerate with `graphify update .`, don't hand-edit) |
| `tool/pulled_db*/**` (captured DB snapshots — read, never edit, never delete) |

**Generated, don't edit:** `lib/data/models/*.g.dart`. Change the model, then run
`dart run build_runner build --delete-conflicting-outputs`. All three `isar_community*`
packages must stay on the exact same version, generator included.

---

## Cross-tier rules

1. **Highest wins.** A request touching several rows runs at the highest model and effort among them.
2. **Route on files, not wording.** List the target files first. "Make the route line thinner" is Sonnet · high (`share_card.dart`); "stop the route line crossing a blackout" is Opus (`track_runs.dart`).
3. **The kind of change can only raise the level.**
   - Anything that changes a **stored** number — distance, duration, moving time, average, max, lean, smoothness, the route blob: **Opus**.
   - Anything that changes how a fix is **accepted, rejected, paused on or re-anchored**: **Opus**.
   - Anything that can **delete or overwrite ride data**, on device or in a pulled DB: **Opus**.
   - Anything that changes what gets **written to an exported file** a rider keeps (GPX, CSV, the share PNG): at least **Sonnet · high**.
   - A **release** build: at least **Sonnet · high**, and only on explicit request — debug is the default for the phone.
4. **Paired files go together.** An Isar model and its regenerated `.g.dart`; a guard and the test that pins it; a write-path rule and the read-path module that must agree with it (`tracking_service.dart` ↔ `track_runs.dart`) — one batch, at the higher of the two rows.
5. **Scope grows, stop.** If the work needs a higher row mid-task, say so and continue only at that level.
6. **Read-only work drops one level.** Questions, searches, explanations, and `tool/` dump runs: Haiku, or Sonnet · medium for Opus areas. No code written.
7. **Reviews match the code**, one level up for Opus areas (high -> xhigh).
8. **Unsure, go one level up** and say why in one line.

## Rules that outrank this file

These come from `CLAUDE.md` and apply at every tier:

- **Never `git commit` or `git push`.** Leave the work in the tree; the user commits.
- **Strict phased delivery** for multi-phase work: finish one phase, then stop and wait for on-device confirmation before the next. An Opus-tier change is almost always phased.
- **Debug on the phone.** Never build or install a release without explicit approval.
- **`flutter analyze` clean** before handing off, and run the tests the change touches.
- Prefer `graphify query "<question>"` over raw browsing when `graphify-out/graph.json` exists, and run `graphify update .` after changing code.

---

_Built from `dev` `36f3f93` (15 Oct 2026). Replaces the routing map of an unrelated Next.js/Vue
repo that this file arrived carrying._
