# Lean angle — design brainstorm

Status: **design only, nothing built.** Written 2026-07-29, grounded in a feasibility
probe (`tool/lean_probe.dart`) run over the 31 real rides in the pulled device DB.

This is the last of the three features planned on 2026-07-13 (place names and the live
speed chart both shipped). The 2026-07-13 note already locked one decision, and the probe
below confirms it was right: **accelerometer-only is out**, because in a steady coordinated
turn gravity and centripetal force resolve down the bike's own vertical axis, so a
bike-fixed accelerometer reads ~1 g and ~0° lean no matter how far over you are.

## The physics

For a bike in a no-slip coordinated turn:

```
θ = atan(v · ω / g)
```

- `v` — ground speed (m/s)
- `ω` — yaw rate (rad/s), i.e. the rate the heading is changing
- `g` — 9.80665 m/s²

Equivalently `θ = atan(v² / (g·R))` for corner radius `R`. This is the lean the corner
*requires* — not the lean the bike *had*. They agree for a normally-ridden motorcycle
(the rider is not hanging off or countersteering hard mid-corner), which is why the
estimate is legitimate, but the distinction is why the UI must say "estimated".

Both inputs already exist in the pipeline: `v` from the Kalman filter, and `ω` from
differencing heading.

## What the probe found

`tool/lean_probe.dart` derives heading as the bearing between stored raw positions —
deliberately the worst case, since `TrackPoint` stores no heading today and this is
exactly what an old-ride backfill would have to use. Three estimators at widening
smoothing baselines, over 26.5k usable samples from 28 rides:

| estimator | baseline | p50 | p95 | p99 | max |
|---|---|---|---|---|---|
| E1 adjacent fixes | ~1 interval (≈1.0–1.4 s) | 3.0° | 13.3° | 23.2° | 54.4° |
| E2 ±1 fix | ~2 intervals | 1.5° | 9.0° | 15.8° | 50.1° |
| E3 ±2 fixes | ~4 intervals (≈4–5.6 s) | 1.1° | 7.8° | 13.8° | 38.1° |

### The noise test settles the estimator

Highway curves are engineered for single-digit lean, so whatever an estimator reports
above 70 km/h is mostly its own error. Over 2,262 high-speed samples:

| estimator | p95 | max | share above 20° |
|---|---|---|---|
| E1 | 14.9° | 54.4° | **2.7%** (61 samples) |
| E2 | 7.6° | 21.5° | 0.1% (2 samples) |
| E3 | **5.9°** | **15.9°** | **0.0%** (0 samples) |

E1 claims you leaned 54° at highway speed 61 times. That is not riding, it is
position noise over a 1.4 s baseline. **Adjacent-fix differencing is unusable; an
E3-class multi-interval baseline is credible.**

### The distribution is physically consistent

E3's |lean| histogram: 90.0% under 5°, 7.0% at 5–9°, 2.3% at 10–14°, 0.6% at 15–19°,
then a near-empty tail. Cross-check: a 90° city turn at 30 km/h on a ~20 m radius needs
`atan(8.3 × 0.42 / 9.81)` ≈ 19.6°, and each such turn contributes only 2–3 samples out of
~1,200 per ride. Twenty turns a ride therefore predicts ~3–4% of samples in the 10°+
bands — and 2.95% is what E3 reports. **The tail is real cornering, not noise.**

Left/right is near-perfectly symmetric (13,605 / 12,920 samples, both maxima 38.1°),
which is a good bias check but also means a left-vs-right stat is unlikely to be
interesting in aggregate.

### Two findings that constrain the feature

1. **Raw max lean is an artifact, not a stat.** The two highest maxima in the whole set
   belong to `260715testontrain` and `260716-2traintestfuse` — the GPS-blackout rides.
   The per-leg dt guards do *not* catch them: E3 still reports 38.1° on both. Publishing
   "max lean 38°" would be publishing a train ride. This is the elevation-spike lesson
   again (raw max 108.7 m → 61.4 m once smoothed), and it means the headline number must
   be a percentile or a corroborated peak, never `max`.

2. **The honest ceiling on this rider's data is ~14–20°.** E3's p99 is 13.8°. These are
   commutes, not canyon runs. The feature will truthfully report mostly-upright riding.
   Worth knowing before investing three phases: it gets interesting on twisty roads and
   stays dull on a city commute.

### The ceiling GPS cannot pass

E3 needs a 4–5 s baseline to be trustworthy, but a corner at 60 km/h is *over* in about
that time. So E3 measures **average lean through a corner**, systematically below the
peak — and it cannot resolve a quick left-right flick at all. No amount of cleverness
fixes this at a ~1 Hz fix cadence; only a different sensor does.

## Design options

### D1 — where `ω` comes from

**Option A: stored positions only (no schema change).** Works today, backfills all 31
existing rides via the existing `RouteBackfill`. But it is locked to the E3-class
baseline the probe just validated, i.e. smeared averages.

**Option B (recommended): add `TrackPoint.headingDegrees`.** The value is already sitting
in `GpsFix.headingDegrees` and being thrown away. It is Doppler course-over-ground, which
is *far* less noisy than differencing two positions — plausibly good enough at an E1/E2
baseline, which is the difference between reporting a corner's average and its peak. Cost
is one additive nullable field and one `build_runner` run (the project has done this twice
already). Old rides fall back to Option A's position-bearing at lower confidence.

The honest part: **we cannot know how much better Doppler course is until we record with
it.** So Option B's first step is to ship the field, record one real ride, and re-run the
probe comparing the two heading sources — *then* pick the baseline with evidence. That
ordering is the Phase 5 lesson (validate the derivation on real data before building UI).

There is a third source worth noting: the Kalman filter already carries a smoothed
velocity vector, so `atan2(_east.vel, _north.vel)` is a free smoothed heading — but it is
smoothed by a filter tuned for *position*, adding lag of its own, and it is only available
live, not for backfill. Mentioned for completeness; not recommended as the primary.

### D2 — what number is the headline

`max` is out (finding 1). Candidates:

- **p95 as "typical cornering lean"** — defensible, stable, and what the probe validated.
- **A corroborated peak** — the largest lean supported by ≥2 consecutive samples, with
  samples adjacent to a blackout/re-anchor excluded outright.
- **A lean histogram / time-in-band** — arguably the most honest presentation, since it
  shows the whole distribution instead of compressing a soft estimate into one hard number.

Recommended: **p95 as the headline stat, plus a corroborated peak**, with blackout-adjacent
samples dropped the way the smoothness module drops out-of-range intervals.

**No lean score.** Smoothness scores 0–100 because smooth is better than rough. Leaning
further is not better than leaning less — it is a fact about the road. Scoring it would
invent a value judgement the data does not support.

### D3 — v1 UI scope

The analysis screen already has a 4-tab `_ChartTabs` (Speed · Zones · Smoothness ·
Elevation) where each tab is height-measured and each chart carries a `ChartFrame` title +
a takeaway computed from the data it draws. Lean fits that pattern as a **5th tab**: lean
vs distance with the scrub/bubble the other charts have, plus the band histogram, and a
takeaway that names the estimate as an estimate.

Recommended v1: **5th tab + a stat on the detail screen.** Deliberately **not** on the
share card — a share card turns a soft estimate into a hard public claim, and the number
is systematically low. Revisit once the Doppler-heading data says how good the estimate is.

Trips combine as max-of-max / pooled percentile, following `TripStats`.

### D4 — the gyro path (real measured lean)

Android's fused `ROTATION_VECTOR` (or gyro + accel directly) genuinely measures roll, and
would capture true peak lean and quick flicks — the exact things GPS structurally cannot.
Costs: a new dependency (`sensors_plus`), a rigid phone mount, a mount-orientation
calibration step, sensor sampling in a background service, battery, and it fails outright
with the phone in a pocket or tank bag. It also cannot backfill a single existing ride.

Recommended: **not in v1.** Note it as the upgrade path if the GPS estimate proves too
soft once real Doppler-heading data is in — possibly as an opt-in "measured lean (beta)"
that supplements rather than replaces the estimate.

### D5 — guards the estimator needs (all confirmed necessary by the probe)

- Heading wraparound normalised to (−180°, 180°] — otherwise 359° → 1° reads as a 358°
  swerve.
- Speed floor ~20 km/h — below it, heading between near-coincident fixes is undefined and
  a slow paddling U-turn manufactures a large `ω` with no lean behind it.
- Per-leg dt window [0.5 s, 10 s], mirroring `kMinAccelDtSeconds` / `kMaxAccelDtSeconds`.
- Reject |lean| > ~55°, **not** clamp — clamping piles fake mass on the cap and makes a
  noisy number look confident.
- Exclude samples spanning a blackout / re-anchor (finding 1 — the dt guards alone are
  provably insufficient).

## What building it changed (2026-07-29)

All three phases are built. Two guards in the shipped module exist only because the
real data refuted an assumption made above.

### Corroboration alone did not defend the peak

The design claimed a peak "corroborated by ≥2 consecutive samples" would defuse the
train-ride artifact. Running the shipped `core/lean.dart` over all 28 rides showed it
did not: `260715testontrain` reported a peak of **36.5°** and `260716-2traintestfuse`
**36.3°**. The reasoning was wrong about the failure mode — a blackout does not produce
*one* junk fix, it produces a run of them, so consecutive samples happily vouched for
each other.

Two guards were added in response:

1. **Smooth-arc (chord ÷ path ≥ 0.80).** Real cornering sweeps an arc; multipath
   zigzags. For a true circular arc turning θ across the window the ratio is exactly
   `cos(θ/4)`, so 0.80 still admits a 147° turn inside one window — far more than road
   riding asks — while a scattered path fails. Effect on real data was surgical: the
   train peaks fell to 11.5° and 10.6° for the cost of **2 dropped samples out of
   ~1,200 per ride**, and normal rides were essentially untouched.
2. **Corroboration raised to 3 samples, and required to agree on direction.** Two was
   worth almost nothing against noise: if scatter throws lean either way at random,
   half of all neighbouring pairs already agree by chance, and seeded random scatter
   duly corroborated a 33° corner. Requiring three consecutive *same-side* samples
   costs genuine cornering nothing, because a corner takes seconds to ride through and
   is sampled repeatedly at ~1 Hz.

Final state over the 28 rides: p95 spans 1.4–10.5°, peaks 1.3–18.4°, and the train
rides sit at 10.7° and 6.3° — no longer outliers, which is correct, since a train ride
contains almost no cornering. Every ride scored; none was left without an estimate.

### An aliasing limit, documented rather than guarded

A yaw rate above `180° / window` cannot be distinguished from its short way round, so
very fast turns are under-read. This is deliberately left unguarded: aliasing only ever
maps a large true rate onto a smaller apparent one, so it can hide an extreme corner but
never invent one — the same direction as every other bias here. Guarding it instead would
discard genuine slow hairpins, which sit at a legitimately high yaw rate (a 12 m radius
at 20 km/h is 26°/s and only ~14° of lean).

### Also worth keeping

- **A periodic zigzag can defeat the chord test** when its period lines up with the
  window spacing, because both window ends land on the same side and it reads as one
  smooth V. What stops it is the direction-agreement rule, not the geometry check.
- **The engine's upstream accuracy gate is part of this defence.** Fixes worse than 25 m
  never reach storage, which is why the real train rides had only 2 bad samples where
  synthetic independent ±30 m scatter produces many. A test that models scatter harsher
  than the engine permits is testing a case that cannot occur.
- The tab is only offered when the ride has an estimate, and the analysis is computed
  once per track rather than per build — deciding whether the tab exists means running
  the estimator, and doing that inside `build` would put two full passes over the track
  on every frame of a tab swipe.

## Proposed phases

Following the strict phased protocol (stop and confirm on device after each).

**Phase 1 — data + evidence.** Add `TrackPoint.headingDegrees` (nullable) and stamp it in
the engine; `build_runner` once. Extend `tool/lean_probe.dart` to compare Doppler course
against position-bearing on a freshly recorded ride. **Deliverable is a decision** — which
heading source and which baseline — not a feature. Cheap, and it de-risks everything after.

**Phase 2 — the pure analysis module.** `core/lean.dart`: `analyseLean(readings) →
LeanAnalysis` carrying samples, p95, corroborated peak, band histogram, left/right split.
Pure and model-free like `core/smoothness.dart`, so tests drive it with synthetic data — a
known-radius circle at known speed has an exactly known lean, which makes for an unusually
strong unit test. Persist to a new nullable `Ride` field via `deriveRoute` + `RouteBackfill`,
exactly as `smoothness` does.

**Phase 3 — UI.** 5th analysis tab + detail stat + trip combination + takeaway lines.

## Decisions — LOCKED 2026-07-29

1. **Build it**, all three phases, as a cornering-character stat rather than a bragging
   number. The rider accepted the ~14° honest ceiling on this data.
2. **D1 Option B** — add `TrackPoint.headingDegrees` and use Doppler course-over-ground,
   with position-bearing as the fallback for rides recorded before the field existed.
3. **D2** — **p95 "typical cornering lean" as the headline, plus a corroborated peak**
   (≥2 consecutive samples, blackout-adjacent samples excluded). No raw max. No score.
4. D3 (5th analysis tab + detail stat, not the share card) and D4 (no gyro in v1) stand as
   recommended above.

Per the "one migration" precedent from Phase 4 of the audit plan, Phase 1 adds the `Ride`
lean fields at the same time as the `TrackPoint` one so `build_runner` runs **once** for the
whole feature — they sit reserved-but-unwritten until Phase 2, exactly as `Ride.smoothness`
did between Phases 4 and 6.

The band histogram is deliberately **not** persisted: the analysis screen already loads the
full track to draw its charts, so it can compute the histogram for free. Only the two
cross-ride comparable numbers earn a column.
