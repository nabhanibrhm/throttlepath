# UX Audit → Build Plan

Source: `ThrottlePath Audit & Redesign.dc.pdf` (22 pages, 32 findings F1–F32, 25 mockups).
Triage done 2026-07-27 against the real code. **Nothing built yet.**

Per `CLAUDE.md`: strict phased delivery — finish one phase, stop, confirm on-device, then next.

---

## Decisions locked before planning

| # | Question | Decision | Why |
|---|----------|----------|-----|
| 1 | Inter or Barlow? | **Keep Inter.** | Bundled Inter TTFs already carry a `tnum` table — `FontFeature.tabularFigures()` works today. Barlow buys only the condensed live-speed numeral. If 64sp feels too wide on-device, add Barlow Semi Condensed later as one extra family for that single number (~40 KB). |
| 2 | Merge the mode enums? | **Yes — merge.** `RecordView{map,chart,none}` × `SpeedGaugeStyle{digital,analog}` → one `RideDisplayMode{dial,number,map,chart}`. | Matches F1 + F4 ("one representation per mode") and makes all four modes discoverable. **Cost: map + analog-dial together becomes unreachable.** Accepted — a dial inside the map sheet would be too small to read anyway. |
| 3 | Route-hash data layer in scope? | **Yes, at Phase 4.** | Coarse start/end geohash + time-of-day bucket. Cheap, and it is what makes auto-naming (F19), PB badges (F17) and "your fastest on this route" possible. Without it Phase 4 loses half its point. |

**Migration discipline:** all new Isar fields land in **one** additive migration in Phase 4
(`routeKey`, `routeBlob`, `smoothness`) so `build_runner` runs once, not three times.
Old rows read null — same pattern as `gpsSource` / `startPlace`.

---

## Phase 1 — Tokens, type scale, red discipline ✅ BUILT & DEVICE-VERIFIED
*Audit Step 1 · fixes F6, F20, F26 (partial), F32*

Nothing else lands cleanly before this.

- [x] 1.1 Extended `AppPalette` (`lib/theme/app_theme.dart`): added `surfaceRaised`, `textTertiary`, `peak`, `positive`, `positiveInk`. Kept `accent`/`accentInk`/`onAccent` — that split already existed and was correct. Dropped the planned separate `hairline`: `border` already is it.
- [x] 1.2 **Rule documented in the palette doc comment: no widget may use `accent` in a `TextStyle.color`.** Text uses `accentInk`. A test guards the rule.
- [x] 1.3 Real type scale — displayLarge 64/w600 tabular · displayMedium 34 · headlineSmall 20 · titleMedium 15/w600 · bodyMedium 13 · labelSmall 12. Applied as an **overlay** on Material's defaults, not a replacement (a wholesale replace nulls `labelLarge`/`bodyLarge` and crashes `ListTile`/`TextButton`).
- [x] 1.4 **12sp floor swept** across 14 files — 9sp and 10sp labels gone. `share_card.dart` exempt as planned. Chart `reservedSize` bumped (34→38 left, 24/26→28 bottom, 40→44 right) so the bigger ticks don't clip.
- [x] 1.5 **Red discipline** — every MAX stat is now `PEAK` on the neutral `peak` token: history cards (ride + trip), Record telemetry row, ride detail, trip detail, ride summary, and the analog gauge's peak marker. Red now appears only on Stop / Discard / Delete / error text.
- [x] 1.6 **Lavender app bar fixed.** Root cause confirmed as predicted: M3 `surfaceTint` over a stock `ColorScheme.light()` with no `AppBarTheme`, tinting in via `scrolledUnderElevation`. Scheme is now built field-by-field; tint killed on AppBar, Card, Dialog, BottomSheet, PopupMenu.
- [x] 1.7 `FontFeature.tabularFigures()` on the live speed numeral, the analog gauge numeral, every stat value and every chart axis tick.
- [x] 1.8 New `test/contrast_test.dart` — 79 tests green.

### Two token values had to change (both were failing AA)
| Token | Was | Now | Why |
|---|---|---|---|
| light `accentInk` | `#B06E00` | `#965D00` | measured **3.95:1** on canvas — below AA. Now 5.4:1, matching the audit's spec. This *is* F32. |
| dark `dangerInk` | `#EF4444` | `#FF6B6B` | **4.43:1** on `surface` — just under AA. Now 6.0:1. |

### One extra fix the contrast test surfaced
`border` was effectively invisible: **1.03:1** on the new dark `surfaceRaised` and 1.13:1 on the light canvas. Now `#303034` dark / `#E2E2DE` light. **Dividers and card outlines will read noticeably crisper — eyeball this on device and say if it's too strong.**

**Verify:** `flutter analyze` clean ✅ · `flutter test` 79 green ✅ · device pass ✅ (2026-07-27, ASUS X01BDA, `adb install -r` over the existing debug build — ride DB byte-identical, all trips/rides present). Walked Record (analog gauge + map), History, Settings, ride detail, trip detail and the chart carousel in **both** themes: **zero** `RenderFlex` overflows or Dart exceptions in logcat. Light-theme app bars confirmed cream, not lavender.

**Open judgement call from the device pass:** the OSM/CARTO map attribution went 9sp → 12sp under the floor rule and now reads quite prominently top-right on the Record map. It is legal boilerplate rather than a label a rider reads, so it is a reasonable exemption alongside `share_card.dart` — say the word and it goes back to 9–10sp.

---

## Phase 2 — Ride screen: mode switcher + idle context
*fixes F1, F2, F3, F4, F5, F7, F8 · ~1 week*

Split into **2A** (no state loss, shipped) and **2B** (the enum merge, still to decide —
see the note under 2.1).

### 2A ✅ BUILT & DEVICE-VERIFIED (2026-07-27)

- [x] 2.4 Dial is now a **fixed** 0–120 km/h (0–80 mph) scale with an emphasised midpoint
      tick, replacing the adaptive `scaleFor(maxSpeed)` — a dial that rescales mid-ride
      points the same speed at a different angle every time, which is the one thing an
      analog readout must not do. Over the top the needle pins and the numeral stays true.
- [x] 2.6 Idle sheet drops the four zeroed stats (F5) for a GPS-readiness row + a **last
      ride** row. Readiness is probed with `isLocationServiceEnabled` + `checkPermission`
      only — cached platform state, no GPS wake and **no permission prompt on app open**;
      an accuracy figure appears only once a real fix exists. New `getLatestFinishedRide()`
      + `latestRideProvider`. *(Week strip is Phase 5 — it needs aggregate queries.)*
- [x] 2.7 Battery-saver "Show map" boxed button → quiet status row with an amber text link
      (F2). START RIDE is now the only filled control on the screen.
- [x] 2.9 Backdrop logo 72px → a 26px mark beside a small wordmark, moved to the upper
      third (F3).
- [~] 2.8 Partial (F7): the view toggle drops its amber outline for neutral ink so recenter
      is unambiguously the action, and both gained `Semantics` labels. Both were already
      52dp. **Merging layer/collapse into the switcher is 2B.**
- [x] Chart-mode empty state biased out from behind the sheet, and the live chart's height
      fraction cut 0.5 → 0.40 so its x-axis clears the sheet. A stopgap: 2.5 replaces it.
- [x] Map attribution exempted from the 12sp floor at 10sp — licence boilerplate was
      outranking the street names underneath it.

**Two audit corrections found by building it:**
1. **F4's "redundant horizontal slider under the dial" was never a slider.** It was the
   needle parked at zero: a uniform-width, round-capped bar lying flat across the mouth of
   the dial, passing through the `0` label, ending in a filled dot — the exact anatomy of a
   track and thumb. Shortening it didn't help; the giveaway is the constant width. Fixed by
   drawing the needle as a tapered wedge. (Earlier triage wrongly concluded no slider
   existed because `grep` found no `Slider` widget.)
2. **F3's "upper area carries the context" is only reachable in one backdrop.** The context
   went into the sheet instead, so it shows in map, chart *and* hidden mode rather than
   only battery-saver.

**Verified:** `flutter analyze` clean in `lib/` + `test/` (35 pre-existing `avoid_print`
infos in `tool/` only) · 80 tests green · installed with `adb install -r`, ride DB intact ·
both themes, both units, all three backdrops walked · logcat clean of overflows.

### 2B — not started

- [ ] 2.1 New `lib/core/ride_display_mode.dart` — `RideDisplayMode{dial, number, map, chart}`. Delete `record_view.dart` + `speed_gauge_style.dart`.
      **⚠ Re-check before building.** The two enums are orthogonal: `RecordView{map,chart,none}`
      × `SpeedGaugeStyle{digital,analog}` = **six** reachable states. A flat 4-way switcher
      deletes three of them and makes the analog dial mutually exclusive with every backdrop
      — including map + dial, which is what the phone is running today. F1's actual complaint
      is that the control lives in Settings, which one inline control can fix without
      collapsing the matrix.
- [ ] 2.2 `SettingsService`: one `ride_display_mode.txt`, reading the two legacy pref files once for continuity, then writing the merged one.
- [ ] 2.3 Inline switcher on the Record screen, persisted. Settings keeps a mirror row, reframed as "Default speed display".
- [ ] 2.5 Chart mode becomes a real mode on the same grid, not a floating overlay — fixes the clipped title + overlapping chip (F8) properly.
- [ ] 2.8 rest — layer/collapse folds into the switcher.

---

## Phase 3 — Recording lifecycle & mis-tap safety
*fixes F10, F11, F12, F14 · part of F13 · ~1 week*

- [ ] 3.1 Glance hierarchy (F14): speed 64sp hero · distance + elapsed 27sp on one line · avg/peak/moving collapsed to one 12sp reference row.
- [ ] 3.2 Pause becomes the **wide primary**; Stop narrows and moves to the far edge (F11). Hold requirement printed *on* the button, not in 10sp grey below it.
- [ ] 3.3 `HapticFeedback` at 50% and on completion of the 2.2s hold (no new dep — currently zero haptics in the repo). Release-early cancels with a "still recording" toast.
- [ ] 3.4 Unmistakable paused state (F12): striped amber rail, desaturated stats, `ELAPSED · FROZEN`, "Not recording — paused 1:27 ago", Resume as wide primary, Stop relabels to **Finish ride**.
- [ ] 3.5 Countdown off by default, opt-in in Settings, tap-to-skip while running (F10).
- [ ] 3.6 Keep-screen-on toggle → **new dep `wakelock_plus`**.
- [ ] 3.7 *(stretch)* tap-to-lock control in the recording bar.

**Verify:** analyze · test · **device pass needs a real ride** (pause/resume accounting must stay correct).

---

## Phase 4 — Ride complete → share loop
*fixes F15, F16, F17, F18, F19 (data), F31 · ~1 week*

- [ ] 4.1 **The one schema migration.** Add to `Ride`: `routeKey` (nullable String — coarse start/end geohash + time-of-day bucket), `routeBlob` (nullable — downsampled polyline for card sparklines, Phase 5), `smoothness` (nullable double, Phase 6). Then `dart run build_runner build --delete-conflicting-outputs`. Mind the `isar_community` version lock.
- [ ] 4.2 Auto-naming from `routeKey` + time of day → "Morning commute" (F19). Keep the raw ID as small mono metadata.
- [ ] 4.3 Name field gets a persistent label + one-tap suggestions, so the common case is zero typing (F16).
- [ ] 4.4 Summary leads with route + distance hero, a comparison to their own average, and any PB earned (F17).
- [ ] 4.5 **Discard leaves the button stack** → text action in the app bar (F15). Confirm dialog states the loss in their numbers: "Delete 15.27 km".
- [ ] 4.6 Trip field appears only *after* choosing "Continue later", as a sheet with a one-sentence explanation of what a trip is (F16).
- [ ] 4.7 Short-ride guard: under 100 m or 60 s → "Looks like this didn't go anywhere — discard?" with Save anyway secondary. Real empty states on detail screens for zero-distance rides (F18).
- [ ] 4.8 **One-sheet share composer** replacing the two-modal chain (F31): full-width live preview, layout as a readable swipeable strip, destinations as a 54dp row. `showShareFlow()` in `share_flow.dart` is the seam.
- [ ] 4.9 GPX export — the existing Kotlin channel is image-only (`MediaStore.Images` / `image/png`); needs a new branch or `share_plus`.

**Verify:** analyze · test · device.

---

## Phase 5 — Rides list
*fixes F20, F21, F22, F23, F24 · ~1–2 weeks*

- [ ] 5.1 Aggregate queries in `DatabaseService` — **there are currently zero** (no `.count()`, no `.sum()`, no `startTime.between()`). `startTime` is already `@Index()`ed, so this is cheap.
- [ ] 5.2 Week strip pinned above the list: distance, rides, streak, delta vs last week (F22) — the core retention answer. Also lands on the Record idle screen (deferred from 2.6).
- [ ] 5.3 Date group headers; collapsing app bar keeping "Rides" + the week total; snap so rows never clip mid-card (F24).
- [ ] 5.4 Card hierarchy: name → distance → route sparkline (from `routeBlob`) → one quiet metrics line. Red gone from list rows entirely (F20).
- [ ] 5.5 Trips render as a bracketed parent with legs nested and a connector line (F21).
- [ ] 5.6 Swipe reveals a **labelled** Delete; row leaves immediately with a 6s **Undo** snackbar (F23). Keep the modal only for discarding a never-saved ride.
- [ ] 5.7 Search + filter chips with counts, running total on the result line, matches highlighted in the route line.

**Verify:** analyze · test · device.

---

## Phase 6 — Analysis & charts
*fixes F25, F26, F27, F28, F29, F30 · ~1 week*

- [ ] 6.1 `PageView` + 4px dots → scrollable **labelled TabBar** (Speed · Zones · Accel · Elevation) (F25).
- [ ] 6.2 Title + one-sentence plain-language takeaway on all four. Chart 1 currently has no title at all.
- [ ] 6.3 Axis labels to 12sp with the unit stated once; `reservedSize` up. *(Note: current axes are 10–11sp, not the 8sp the audit claims — smaller change than budgeted.)*
- [ ] 6.4 Downsample to ~300 points before painting (1 Hz traces are drawing thousands — that is the swipe stickiness).
- [ ] 6.5 Drag-to-scrub + value bubble on charts 2–4. *(Chart 1 already ships this via `SpeedDistanceChart(interactive: true)`.)* Legend chips actually toggle series.
- [ ] 6.6 Zones: delete the donut, keep the table, add one stacked bar ordered slow→fast, labelled in place (F27). A `Row` of `Expanded` flex segments — no chart library needed.
- [ ] 6.7 Accel → **smoothness score /100** with "smoother than 8 of your last 10 rides" (reads `Ride.smoothness` persisted in 4.1 — otherwise it loads 10 full tracks). Bands labelled "accelerating"/"braking"; axis states km/h/s (F28).
- [ ] 6.8 Elevation: left tick labels amber, right teal, colour-tied to their series (F28).
- [ ] 6.9 Map tap-to-expand full screen; legend gets numeric ticks (F30).
- [ ] 6.10 Unify app bars — back · title (tap to rename) · share · overflow on **both** ride detail and trip detail (F29). "Reopen trip" becomes "Add the next leg".

**Verify:** analyze · test · device.

---

## Phase 7 — Settings regroup + accessibility
*fixes the rest of F32, homes the F13 settings · ~3–4 days*

- [ ] 7.1 Regroup: UNITS · DISPLAY · RECORDING · DATA · About. Every row ≥48dp.
- [ ] 7.2 "Dark mode" → three-way **Theme (System / Light / Dark)**. `SettingsService.loadThemeMode` currently collapses `ThemeMode.system` into dark — that has to change.
- [ ] 7.3 Export all rides (GPX or CSV) under DATA.
- [ ] 7.4 A11y pass: `Semantics` labels on every icon-only button (app-bar pencil, share, recenter, overflow are all unlabelled to TalkBack); `liveRegion: true` on live speed with a spoken form, throttled to 5s; `Semantics` summary on charts reusing the takeaway sentence; `MediaQuery.textScaler` so labels reflow instead of clipping.

---

## NOT doing (and why)

| Item | Status | Reason |
|------|--------|--------|
| **F13 speed-based auto-pause** | **Push back** | The engine already has a *validated* signal-loss auto-pause + pause accounting (`tracking_service.dart:44-52`, `:321-333`), a Kalman anchor drop on resume, and a 3 km/h moving-time gate. A second auto-pause mechanism risks the accounting that fixed the train-blackout bug. If wanted, do it dead last, alone, with a real ride to verify. |
| **F9 satellite count + 4-bar meter** | Out of scope this round | geolocator's `Position` exposes **no** GNSS status. Needs the app's first native `EventChannel` over `LocationManager.registerGnssStatusCallback` (API 24+, fine on the API 28 test device). Possible, just not cheap. |
| **F9 "usually takes ~20 s"** | **Impossible as specified** | Android has no time-to-first-fix API. Only fakeable with a locally-learned rolling average. Recommend dropping the line rather than inventing it. |
| **F9 "Start anyway"** | Deferred | Means creating the `Ride` row before a usable fix. `beginRecording()` currently fires only after the first fix clears the 25 m accuracy gate — this touches the recording core. |
| **Notification pause/stop buttons** (part of F13) | **Not possible** | `flutter_background_service` exposes title/content only, no actions. *(The audit's "no state-mirroring notification" claim is also wrong — it already has 4 branches including GPS-signal-lost, `tracking_service.dart:513-544`.)* |
| **Barlow / Barlow Semi Cond / IBM Plex Mono** | Unnecessary | Inter already has `tnum`. See decision 1. |
| **Lap button** (mockup 6) | Not in scope | Appears in a mockup but in no finding — it is a whole new feature, not a fix. |
| **Weekly goal** | Not requested | The audit raises it as an open question. Week strip first; a goal only if it proves useful. |
| **Story 9:16 share format** | After Phase 4 | Nice-to-have once the composer exists. |

---

## Audit errors — do not rebuild what already exists

1. **F22 "no empty state"** — `_EmptyState` exists at `history_screen.dart:138`. The rest of F22 (totals/search/filter/grouping) is valid.
2. **F19 "machine IDs as ride titles"** — `260724-1f` etc. are names the **user typed** on test rides. The code is `ride.name ?? 'Untitled ride'`. The real gap is that no auto-naming exists at all.
3. **F26 "8sp axes"** — actually 10–11sp. True 8sp only on the share card.
4. **F26 "untouchable charts"** — drag-to-scrub + value bubble already ships on chart 1. Charts 2–4 are the gap.
5. **F13 "no state-mirroring notification"** — it has four branches including GPS-signal-lost.
6. **F32 root cause** — the `accent`/`accentInk` token split the audit prescribes **already exists** (light ink is `#B06E00`). The lavender app bar is M3 `surfaceTint` + no `AppBarTheme`. Much cheaper than budgeted.
