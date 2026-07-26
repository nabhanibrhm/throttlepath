# ThrottlePath

**Offline-first riding telemetry for motorcycles.** A dark, high-contrast trip
computer that records your ride from the GPS chip up — no account, no sync, no
network required. Everything lives on the phone.

Built with Flutter for Android.

---

## What it does

You hit **START**, ride, and hit **STOP**. In between, ThrottlePath keeps a
foreground service alive so tracking survives a locked screen, a pocket, and a
sleeping CPU — the failure mode that makes most phone-based trackers useless on
a bike.

### Live dashboard

- Current speed, average speed, distance and duration, updated per GPS fix.
- **Digital or analog speed readout.** The analog gauge is a half-moon dial
  whose top-of-scale adapts to the ride's own peak, so a city commute uses the
  whole sweep instead of hugging the left stop.
- Route drawn live on an OpenStreetMap layer, coloured by speed.
- Pause / resume, a 3-2-1 countdown before recording, and hold-to-stop so a
  jostle can't end your ride.
- Locate-me, plus a map-off mode when you want telemetry without the tiles.

### After the ride

- A summary screen with the full stat block, the route, and speed / elevation /
  accel-brake charts.
- Save it, name it, or discard it.
- **Share card** — a rendered PNG summary with the route and headline stats.
- Start and end **place names**, reverse-geocoded when a network happens to be
  around (and left blank when it isn't — the app never blocks on it).

### Trips

A **trip** is a multi-leg journey: ride out, stop for lunch, ride home. Each leg
is saved as its own ride, but the trip rolls them up into one total and stays
open until you finish it — and can be reopened afterwards to add another leg.
Trip stats deliberately **exclude** the time parked between legs, so a round
trip reports the time you actually spent riding.

Trips and legs are named independently, and both can be renamed.

### History

Every saved ride and trip, with route maps, the full stat block, and per-leg
start→end place labels.

---

## GPS quality

Consumer GPS lies, and a bike makes it worse — vibration, tunnels, lane-splitting
between metal. The pipeline that turns raw fixes into a believable ride:

- **Raw GNSS only.** An A/B test against Android's fused provider was run on real
  rides and raw won outright; the fused variants were removed rather than left as
  dead config.
- A **Kalman filter** on position, plus outlier rejection on implausible jumps.
- **Signal-loss guards** — a long-gap re-anchor and an accuracy-reject streak that
  stop a tunnel or an underground car park from being drawn as a phantom
  straight-line kilometre.
- Distance by **Haversine**, and moving time computed separately from wall-clock,
  so a traffic light doesn't drag your average down.

---

## Design

One accent colour — amber `#FFB22C` — over a near-black canvas, with a light
theme that keeps the same accent. Big numerals, generous tap targets, no chrome
competing with the road. **Inter** is bundled as an asset so type renders
correctly on the first launch, offline.

Everything is stored and computed in **metric**; km/h ↔ mph converts at display
time only.

---

## Stack

| | |
|---|---|
| Framework | Flutter (Dart SDK `^3.12.2`) |
| State | Riverpod (`flutter_riverpod` 2.6.x) |
| Database | `isar_community` 3.3.2 — embedded NoSQL, the maintained fork of `isar` |
| Location | `geolocator` + `flutter_background_service` (Android foreground service, `type=location`) |
| Maps | `flutter_map` v8 (OSM tiles, disk-cached) + `latlong2` |
| Charts | `fl_chart` |

Android `applicationId`: `id.co.opentrack.throttlepath`

---

## Getting started

Requires the Flutter SDK (stable) and a JDK 21 — Android Studio's bundled JBR
works:

```bash
flutter config --jdk-dir "<path to Android Studio>/jbr"
```

Then:

```bash
flutter pub get
flutter run --debug          # on a connected device
```

Regenerate the Isar adapters after editing a model in `lib/data/models/`:

```bash
dart run build_runner build --delete-conflicting-outputs
```

Helper scripts (PowerShell, from the repo root):

```powershell
scripts/deploy-debug.ps1     # debug build onto the connected phone
scripts/build-release.ps1    # release APK, archived with a version stamp
```

### Checks

```bash
flutter analyze
flutter test
```

---

## Layout

```
lib/
  core/        units, Haversine, Kalman filter, speed palette, view enums
  data/        Isar models (Ride, TrackPoint, Trip), database service, trip stats
  providers/   Riverpod providers — tracking, history, home, settings
  services/    location source, tracking engine, geocoding, tiles, share, prefs
  theme/       the two colour schemes
  ui/          screens, charts, the speed gauge, the share card
test/          Kalman step response, trip stat rollups, gauge scaling
tool/          offline diagnostics — not part of the app build
```

`tool/dump_ride.dart` reads a pulled copy of the on-device database and
recomputes distance and speed from the raw track points, flagging GPS gaps and
jumps. It's how the guards above were validated against real rides.

---

## Status

Working and in daily use on a physical Android 9 device. Android only for now —
the iOS side is scaffolded but untested.

## License

[MIT](LICENSE)
