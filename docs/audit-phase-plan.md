# UX Audit → Build Plan

Source: `ThrottlePath Audit & Redesign.dc.pdf` (22 pages, 32 findings F1–F32, 25 mockups).
Triage done 2026-07-27 against the real code. **Nothing built yet.**

Per `CLAUDE.md`: strict phased delivery — finish one phase, stop, confirm on-device, then next.

---

## Decisions locked before planning

| # | Question | Decision | Why |
|---|----------|----------|-----|
| 1 | Inter or Barlow? | **Keep Inter.** | Bundled Inter TTFs already carry a `tnum` table — `FontFeature.tabularFigures()` works today. Barlow buys only the condensed live-speed numeral. If 64sp feels too wide on-device, add Barlow Semi Condensed later as one extra family for that single number (~40 KB). |
| 2 | Merge the mode enums? | ~~Yes — merge into `RideDisplayMode{dial,number,map,chart}`.~~ **REVERSED 2026-07-27: keep both axes.** `RecordView` and `SpeedGaugeStyle` stay separate; one inline control exposes both. | The merge was accepted believing it cost one combination. It doesn't: the enums are orthogonal, so 3 backdrops × 2 gauges = **six** reachable states, and flattening to four deletes three of them — map+dial (in use today), chart+dial and off+dial. F1's actual complaint is that the control lives in Settings, three taps from what it changes; that's fixable with one inline control without collapsing the matrix. |
| 3 | Route-hash data layer in scope? | **Yes, at Phase 4.** | Coarse start/end geohash + time-of-day bucket. Cheap, and it is what makes auto-naming (F19), PB badges (F17) and "your fastest on this route" possible. Without it Phase 4 loses half its point. |

**Vindicated at build time:** decision 3 carried Phase 4 *and* Phase 5. The same
`routeKey` drives auto-naming, route records and the repeat-route sentence; the
`routeBlob` beside it is what makes a History row recognisable without a query. Both
backfill onto existing rides from data already on disk — no network, so they converge in
a few History visits rather than never.

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

### 2B ✅ BUILT & DEVICE-VERIFIED (2026-07-27)

**Approach: keep both axes** (see decision 2). `RecordView` and `SpeedGaugeStyle` both
survive; no enum merge, no `ride_display_mode.dart`, **no pref migration** — the existing
`record_view.txt` and `speed_gauge_style.txt` keep working, so no saved preference was
disturbed.

- [x] 2.1 `lib/ui/ride_display_switcher.dart` — two segmented groups in one row (Map · Chart ·
      Off | Dial · Number), inside the telemetry sheet under the drag handle. A dumb widget:
      values in, callbacks out. Replaces the floating pill that *blind-cycled* map → chart →
      off; tapping "Off" now selects Off instead of advancing from wherever you were.
- [x] 2.2 Settings mirror regrouped under a **RIDE SCREEN** section (Backdrop · Live speed),
      with Speed unit + Dark mode left under DISPLAY. Both surfaces read their text from
      `RecordView.label` / `SpeedGaugeStyle.label`, so the wording cannot drift.
      `SpeedGaugeStyle.label` changed "Digital"/"Analog" → "Number"/"Dial" — the rider is
      picking a shape, not a technology, and the shorter words fit a segmented control.
- [x] 2.3 Recenter is now the only floating control (F7 complete).
- [x] 2.4 Both backdrops take a `bottomInset` of the sheet's **measured** height and lay out
      in the strip above it, replacing 2A's `Alignment(0, -0.55)` and `maxHeight * 0.40`
      guesses. `SafeArea(bottom: false)` — the sheet already covers that area and applies its
      own inset. F8 fixed properly.
- [x] 2.5 Off + Dial and Off + Number, newly reachable, both read correctly on bare canvas.
      The "Show map" text link is gone: the switcher is always on screen, so Off is no longer
      a state needing its own escape hatch.
- [x] Camera re-centres when the sheet resizes. Dial → Number shortens the sheet ~110dp, and
      the offset is only applied at `move()` time, so the rider's marker drifted off-centre
      until the next fix. `_measureSheet` now re-issues the move.

**Two follow-ons this created:**
- `_measureSheet` had to start calling `setState` (2A deliberately avoided it). Safe: the
  sheet sizes itself from its own content, never from `_sheetHeight`, so the `!=` guard
  terminates after one extra frame.
- `ExcludeSemantics` around each segment's `Text`, so TalkBack announces "Backdrop: Chart"
  once rather than that plus a bare "Chart".

**Verified:** analyze clean in `lib/` + `test/` · 88 tests green (8 new in
`test/ride_display_switcher_test.dart`, incl. a guard that fails if anyone re-flattens the
enums) · all **six** combinations walked on device, both themes · logcat clean.

---

## Phase 3 — Recording lifecycle & mis-tap safety ✅ BUILT & DEVICE-VERIFIED
*fixes F10, F11, F12, F14 · part of F13 · ~1 week*

- [x] 3.1 Glance hierarchy (F14): speed hero 60→**64sp** · distance + elapsed promoted to a
      two-up **27sp** row (`_HeroStat`) · avg/peak/moving collapsed into one 12sp
      `_ReferenceStats` line. The old 4-up `_Metric` grid put all four at the same 20sp,
      which is no hierarchy at all; `_Metric` is deleted.
- [x] 3.2 Pause is the **wide primary** (flex 2:1, and 3:2 once paused so `RESUME` keeps the
      weight); hold-to-end is narrow and at the far edge. The requirement is printed **on**
      the button (`STOP` / `HOLD 2.2s`) instead of in grey text below it, and mid-hold that
      sub-label becomes the live countdown. New `_RideControls` owns the bar.
- [x] 3.3 `HapticFeedback` at the halfway latch (`lightImpact`) and on completion
      (`heavyImpact`) — the repo had zero haptics before. Releasing early **cancels
      outright** (snaps the fill to zero rather than animating back, so a cancelled hold
      can't be misread as one in progress) and toasts "Still recording".
      *Beyond the plan:* `mediumImpact` on Pause/Resume too — a gloved thumb gets no
      travel and no click, so haptic is the only confirmation the tap landed.
- [x] 3.4 Unmistakable paused state (F12): full-width **striped amber rail** across the top
      of the sheet (`_StripedRail`, outside the horizontal padding), **filled** `PAUSED`
      chip instead of the old small outlined badge, stats desaturated to `textDim`,
      `ELAPSED · FROZEN` on the label, "Not recording — paused 1:27 ago" in words, and
      Stop relabelled **FINISH RIDE** — the destructive verb only appears when ending the
      ride is actually what the rider wants.
- [x] 3.5 Countdown **off by default**, opt-in under a new Settings **RECORDING** section,
      and the counting-down number itself is the skip target (pill reads `TAP TO SKIP`).
- [x] 3.6 Keep-screen-on toggle → **new dep `wakelock_plus` 1.7.0** (resolved and compiled
      clean). Off by default; held for the whole ride including pauses, released on stop.
- [ ] 3.7 *(stretch)* tap-to-lock control in the recording bar. **Not done** — a
      touch-swallowing overlay is a feature, not a fix, and F13's lock is the part of that
      finding with no BLOCKER behind it.

### Two things worth knowing

**A second freeze already existed, and the screen never admitted it.** The engine's
signal-loss auto-pause (`signalLostAt`) freezes the ride clock exactly as a manual pause
does, but nothing on screen said so — a stalled clock with no explanation reads as a bug.
`signalLost` now crosses to the UI alongside `pausedAtMs`, and the same frozen treatment
covers it with its own wording (`GPS SIGNAL LOST` / "Not recording — waiting for GPS").
Kept **amber, not red**, to stay inside Phase 1's red discipline. This is an addition to
the plan, not something the audit asked for — say the word and it comes out.

**Turning the countdown off exposed a latent double-start race.** `beginRecording()`
deliberately leaves `phase` alone until the `Ride` row exists ("so an in-flight fix can't
persist against rideId 0"), and the `'countdown'` phase used to cover that window
synchronously. With the countdown off, GPS lock calls straight through, so `phase` stayed
`'acquiring'` across the `await db.saveRide()` — a second fix landing in that window would
have started **a second ride row**. Guarded with a `beginningRecording` latch released in a
`finally`, so a failed save can still be retried instead of wedging the ride in `acquiring`
with its timeout already spent.

### One regression this created, caught only on device

**The acquiring screen showed four zeros again.** `hasTelemetry` was `tracking || lastFinished`,
so during `'acquiring'` and `'countdown'` — when no ride exists yet — the stats block rendered
`0.00 km / 00:00 / AVG 0.0 / PEAK 0.0`. That is exactly the F5 problem 2A removed from the idle
screen, and 3.1 made it twice as loud by promoting two of those zeros to 27sp. Now keyed on
`recording || lastFinished` (`'recording'` covers paused, since pausing doesn't change the
phase), so acquiring falls through to the GPS-readiness row — the honest content for that
moment. **Screenshot the pre-ride phases, not just the riding one.**

**Verify:** `flutter analyze` clean in `lib/` + `test/` ✅ · **99 tests green** ✅ (11 new in
`test/recording_lifecycle_test.dart`) · `flutter build apk --debug` succeeds with the new dep ✅ ·
`adb install -r` over the existing debug build, ride DB intact ✅.

**Device pass done 2026-07-28** (ASUS X01BDA, three throwaway rides, all discarded; History and
the Jul 25–28 trips verified untouched afterwards). Walked in **both themes**: acquiring (GPS
readiness, no zeros), recording, paused, and the finished summary. Confirmed on device —
striped rail spanning edge to edge under the rounded corners · filled PAUSED chip ·
"Not recording — paused 13s ago" **ticking live** off `pausedAtMs` (so the isolate plumbing
works) · `ELAPSED · FROZEN` with values dropped to `textDim` · PAUSE wide / STOP narrow with
`HOLD 2.2s` **on** the button and no grey hint line at rest · release-early cancel toasting
"Still recording — keep holding to end the ride." with the ride still running · completing
hold finalising the ride · countdown **off** by default going straight from GPS lock to
recording · Settings RECORDING section with both toggles off and the countdown subtitle
switching with its state. Logcat clean — zero `RenderFlex` overflows, zero Dart exceptions.

**Two things not visually confirmed:** the countdown's own 3-2-1 rendering (`TAP TO SKIP` pill)
was never captured — it is a 3-second window and each `adb` round-trip costs ~1s. Tap-to-skip
itself is evidenced indirectly: with the countdown *enabled*, recording began at `ELAPSED 00:01`
with zero countdown frames across 16 captures while tapping the hero each iteration. And the
**haptics could not be verified over adb at all** — worth a deliberate check by hand.

**Still wants a real ride.** Everything above was stationary indoors: moving time stayed
`00:00` and distance never exceeded 0.02 km, so pause/resume accounting is only shown to be
*self-consistent*, not correct against real movement. The GPS-blackout rail has never been
seen in the wild either.

**Decided 2026-07-28 — `FINISH RIDE` keeps the `danger` red.** Raised as a judgement call (the
relabel from STOP softens the wording, so keeping the same red only half-does it) and settled in
favour of red: ending a ride is terminal, and red + hold is the mis-tap protection. This is a
sanctioned exception to Phase 1's red discipline, alongside Stop / Discard / Delete / error text
— **don't "fix" it in a later phase.**

**Known pre-existing logcat noise, not Phase 3:** `flutter_background_service_android` logs
"This class should only be used in the main isolate" — its own `registerWith()` throws when
`DartPluginRegistrant.ensureInitialized()` registers it inside the background isolate. Caught
and logged by Flutter's registrant; harmless, since the isolate uses `ServiceInstance`. The
`geocoding` plugin's `Geocoder$GeocodeListener` `ClassNotFoundException` is likewise an API-33
class missing on this API-28 device, with a sync fallback.

---

## Phase 4 — Ride complete → share loop ✅ BUILT & DEVICE-VERIFIED
*fixes F15, F16, F17, F18, F19 (data), F31 · built with Phase 5 in one pass*

- [x] 4.1 **The one schema migration**, exactly as planned: `routeKey` (`@Index()`ed — it
      is the join key for auto-naming, route records and "fastest on this route"),
      `routeBlob` (`List<double>?`, interleaved `[lat, lon, …]`), `smoothness`
      (reserved, still written by nobody — Phase 6 owns it). `build_runner` ran once.
- [x] 4.2 Auto-naming in `lib/core/route_key.dart`: 5-char geohash of each endpoint
      (~4.9 km cells, deliberately loose so parking one street over still matches) +
      a time-of-day band → `qqguw>qqgv2@morning`. Names read off it — "Morning
      commute" once a route repeats twice, "Morning loop from Dago" when the ends
      share a cell, "Morning ride to Lembang" otherwise.
- [x] 4.3 Name field has a permanent `RIDE NAME` label and arrives **pre-filled**
      with the best suggestion; the alternatives are 36dp chips below it. The common
      case is now read-and-save — no typing, no tapping. Backing out of the summary
      also applies the suggestion (it used to leave "Untitled ride" forever), but
      never over a name the rider typed.
- [x] 4.4 Summary leads with place route → distance hero + route sparkline → one
      comparison sentence ("18% further than your average · ridden this route 3
      times before"), with filled amber award badges above it when a record fell.
      Four awards: longest distance, fastest average, longest time, fastest on this
      route. Gated on ≥1 km and on the rider *having* a history, so a first test
      ride can't crown itself.
- [x] 4.5 Discard is a text action in the app bar; the confirm reads
      **"Delete 0.03 km"**. Two buttons left in the stack, not three.
- [x] 4.6 The trip-name field is gone from the summary. `CONTINUE AS A TRIP` opens a
      sheet that explains what a trip is in one sentence, then asks for the name.
- [x] 4.7 Short-ride guard fires on the summary's first frame under 100 m or 60 s:
      "Looks like this didn't go anywhere — 26 m in 00:40", Discard leading, Save
      anyway secondary. Detail screens got a real `NoTrackNotice` — the old empty
      state was a 50%-dimmed map of *Jakarta*, which to a rider in Bandung reads as
      a failed tile load or a route recorded somewhere they've never been.
- [x] 4.8 **One-sheet share composer.** The preview *is* the sheet; swiping it
      changes layout and moves a labelled chip strip (four unlabelled dots told the
      rider how many styles existed and nothing about which one they were looking
      at); destinations are a 54dp row of three. The old flow made them commit to a
      postage-stamp thumbnail and *then* answer a question they hadn't been asked.
- [x] 4.9 GPX 1.1 export (`lib/services/gpx_export.dart`) — one `<trkseg>` per trip
      leg, `<ele>` only where a fix reported one, speed in `<extensions>` (1.1
      dropped `<speed>` from `trkpt`). Needed **one** new Kotlin method,
      `shareFile(path, mimeType, title)`: the existing `shareToInstagram` is a
      targeted ADD_TO_STORY intent with an explicit package grant, which GPX has no
      use for. `share_plus` was not added — it would have wanted its own
      FileProvider next to the one already configured.

**Verify:** analyze clean ✅ · **194 tests green** ✅ (61 new) · debug APK builds with
the Kotlin change ✅ · `adb install -r` over the existing build, **ride DB intact**
(30 entries, 419 km in July — byte-for-byte the same before and after) ✅.

**Device pass 2026-07-28**, both themes, two throwaway rides both discarded. Confirmed:
the summary's award/comparison block, pre-filled "Evening loop" with an "Evening ride"
chip, app-bar Discard → "Delete 0.03 km", the short-ride prompt with real numbers, the
composer's swipe-to-change-layout, and **GPX actually leaving the phone** — the system
chooser opened on WhatsApp/Gmail/Drive and the file pulled back off the device is
well-formed (`<?xml…><gpx version="1.1"…>`, 642 KB, one `trkseg`, correct `</gpx>`).
Logcat clean of overflows and Dart exceptions.

---

## Phase 5 — Rides list ✅ BUILT & DEVICE-VERIFIED
*fixes F20, F21, F22, F23, F24*

- [x] 5.1 Aggregate queries in `DatabaseService` (there were zero): `getRidesStartedSince`
      walks the existing `startTime` index as a **where-clause**, and `getRiderStats`
      reduces with `count()` / `sum()` / `max()` on property queries so no `Ride` is
      ever materialised. Every lifetime figure is computed **excluding** the ride
      being judged — otherwise a just-saved ride ties its own record and is compared
      against an average it is part of.
- [x] 5.2 Week strip: distance, rides, moving time, streak, delta vs last week.
      A `compact` one-line variant lands on the Record idle screen (deferred here
      from 2.6). Streak counts back from *last* week when the current one is still
      empty — otherwise every Monday morning reads as a broken streak.
- [x] 5.3 **Month** group headers with each month's total, and a collapsing
      `SliverAppBar` (`floating` + `snap`, so it is never parked halfway across a
      card) that keeps "Rides · 59.2 km this week" once the strip is out of the way.
- [x] 5.4 Card hierarchy: name → distance → **route sparkline** → one quiet metrics
      line. No red anywhere in a row; peak carries the neutral `peak` token.
- [x] 5.5 Trips are a bracketed parent (a 3dp amber edge down the left, spanning the
      header via `IntrinsicHeight`) that expands in place to nested legs on a
      numbered connector — the last leg's line stops at its own node, since a line
      running past it implies another leg is coming.
- [x] 5.6 Swipe reveals a **labelled** red Delete; the row leaves at once and a 6s
      Undo snackbar is the safety net. Nothing reaches the DB until that window
      closes — and `dispose` commits any pending delete, so a rider who swipes and
      immediately leaves doesn't find the row resurrected next launch.
- [x] 5.7 Search over names *and* place names, filter chips carrying live counts
      (computed over the searched set, so a chip can't promise rows it won't
      deliver), a running total on the result line ("26 results · 348.4 km"), and
      matches picked out in amber in the route line.

**Deliberate simplification:** the search field and filter chips scroll away with the
list instead of pinning under the app bar. Pinned, they cost ~90dp of permanent chrome
on every scroll; you search once and then browse the results.

**Verify:** analyze clean ✅ · 194 tests green ✅ (`test/history_list_test.dart` pumps the
real screen with the DB providers overridden, at the device's 353dp width, in both
themes) ✅ · device pass on 30 real entries across 5 trips ✅.

### The tests had to load the real font before they were worth anything

The first overflow run failed on layouts that are fine in the app: the test binding
falls back to a placeholder font whose every glyph is a square of the font size, ~40%
wider than Inter. It would have pushed the design into shrinking to satisfy a font
nobody ships. `test/history_list_test.dart` now loads the bundled Inter TTFs in
`setUpAll` and pins the surface to 353 × 760 — a `MediaQuery` override alone changes
only what widgets *read*, not the box they are laid out in, so the 800 × 600 default
was hiding every horizontal overflow in a card.

### Five things only the device caught

1. **The metrics line wrapped**, stranding "peak km/h" alone on a second row. It ran to
   61 characters with moving time in it. Moving time is now left to the detail screen.
2. **47dp of dead space under the week strip.** The reserved height was guessed at 138dp
   against a real 92dp. The strip is also no longer given a fixed height at all — a
   `Positioned` with left+right+top leaves the vertical constraint loose, so a larger
   system text scale clips gracefully instead of throwing.
3. **A week down 58% drew `trending_flat`**, which says "level" — the opposite of what
   happened. Three-way now; down stays neutral ink, because riding less is not an error.
4. **Sparklines used a third of the card.** Aspect ratio was being preserved, which is
   right in a square box and wrong in a 290 × 44 one: a north–south Bekasi commute
   became a narrow squiggle in an empty strip. Each axis is now normalised
   independently — a sparkline is read on its *pattern of turns*, and the real geometry
   is one tap away on the map.
5. **"100% shorter than your average"** on a 26 m recording — arithmetically right,
   semantically nonsense (100% shorter is zero). No comparison is drawn below the 1 km
   award floor. The same recording had also been stamped with a `routeKey` (both ends in
   one coarse cell) and announced as "ridden this route once before"; a key is a claim
   about where you went, so nothing under `kRouteMinDistanceMeters` (200 m) gets one —
   and nothing under it draws a sparkline either, since that trace is pure GPS drift.

**Still wants a real moving ride.** Both throwaway recordings were stationary indoors,
so the route key stamped at ride end has only been exercised on a 6 m wiggle live; the
backfill path over 25 real rides is what proves the derivation, and it does look right
(two directions of the same commute draw as mirror images, start/end dots swapped).

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
