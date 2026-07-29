import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The severity ramp for lean angle: one hue, deepening with magnitude.
///
/// **Single-hue on purpose.** Lean magnitude is a *sequential* quantity, and a
/// green→red ramp is the language of *status* — it says "this value is bad". The
/// external audit proposed exactly that, borrowed from a MotoGP graphic, and it was
/// declined for two reasons. It reintroduces the value judgement this feature
/// deliberately refuses (there is no lean score, because leaning further is not
/// better riding — it is a fact about the road), and a rainbow for a magnitude is a
/// known anti-pattern: position on the axis already carries the number, so colour
/// only has to carry *how much*, which one hue does.
///
/// **Calibrated to the bike, not to the data.** The ramp spans
/// 0 → [kLeanScaleMaxDegrees], because a road bike scrapes a footpeg near 45°.
/// The audit's scale saturated at 25°, which would paint an ordinary commute in
/// alarm colours — this rider's rides peak near 18°. Under this ramp 18° is
/// mid-amber, which is what 18° actually is.
///
/// Both ramps are strictly monotonic in OKLab lightness with ≥0.03 steps and every
/// step clears 3:1 against its own surface. Dark mode is stepped separately rather
/// than flipped: on a dark canvas a sequential ramp runs dim→bright, on a light one
/// light→dark.

/// Top of the lean scale, in degrees — the gauge's full sweep and the point where
/// the ramp reaches its deepest step. A road bike is scraping hard parts here.
const double kLeanScaleMaxDegrees = 45.0;

/// Dim → bright amber, for the near-black canvas.
const List<Color> _darkRamp = [
  Color(0xFF8A5A16),
  Color(0xFFB5761C),
  Color(0xFFD99424),
  Color(0xFFFFB22C), // the app's accent sits fourth
  Color(0xFFFFD07A),
];

/// Light → dark amber, for the paper canvas. Stepped down far enough that even the
/// lightest fill clears 3:1 on `#FAFAF7`; the audit's own light steps sat at
/// 1.28:1, which is an invisible bar.
const List<Color> _lightRamp = [
  Color(0xFFBF8521),
  Color(0xFFA7751D),
  Color(0xFF8F6108),
  Color(0xFF7A4E00),
  Color(0xFF5E3B00),
];

/// The ramp's anchor stops for the active theme, low lean first.
List<Color> leanRamp(AppPalette cx) => cx.isDark ? _darkRamp : _lightRamp;

/// The colour for a lean of [degrees] (sign ignored — magnitude is what the ramp
/// encodes), interpolated between the anchor stops.
Color leanSeverityColor(AppPalette cx, double degrees) {
  final ramp = leanRamp(cx);
  final t = (degrees.abs() / kLeanScaleMaxDegrees).clamp(0.0, 1.0);
  final scaled = t * (ramp.length - 1);
  final i = scaled.floor().clamp(0, ramp.length - 1);
  if (i >= ramp.length - 1) return ramp.last;
  return Color.lerp(ramp[i], ramp[i + 1], scaled - i)!;
}

/// The severity bands the gauge paints and the legend would name, as
/// `(fromDegrees, toDegrees, colour)` across the full scale.
///
/// Ten-degree bands rather than the histogram's five: the gauge is read at a
/// glance, and five bands over 45° is more edges than an arc that size can show.
List<({int from, int to, Color color})> leanBands(AppPalette cx) {
  const step = 10;
  return [
    for (var from = 0; from < kLeanScaleMaxDegrees; from += step)
      (
        from: from,
        to: (from + step).clamp(0, kLeanScaleMaxDegrees.round()),
        // Mid-band colour, so a band reads as the lean it represents rather than
        // as its own lower edge.
        color: leanSeverityColor(cx, from + step / 2),
      ),
  ];
}
