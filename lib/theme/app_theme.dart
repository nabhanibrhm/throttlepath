import 'package:flutter/material.dart';

/// ThrottlePath palette — a single four-colour identity (near-white, amber, red,
/// near-black) drives both themes, matching the design prototype. The
/// near-white/near-black poles swap between light and dark, while amber (accent)
/// and red (danger) stay put as the shared accents.
///
/// Amber reads well as both a *fill* and as text on the near-black canvas, so on
/// dark the "ink" variant equals the fill. On a light canvas amber vanishes as
/// text, so light carries a deepened amber "ink" variant for text, icons, and
/// lines. Widgets read the active set via [AppColors.of].
///
/// ## The two colour rules
///
/// 1. **Never put [accent] (or [danger]/[positive]) in a `TextStyle.color`.**
///    The bare tokens are *fills*. Text, icons and hairlines use the matching
///    `…Ink` variant, which is darkened per theme to clear WCAG AA. Amber at
///    `#FFB22C` on white measures 1.9:1 — unreadable in sunlight, which is the
///    single worst accessibility failure the UX audit found.
/// 2. **Red means irreversible, and nothing else.** Stop, Discard, Delete. Peak
///    and max values use the neutral [peak] token instead — ten red rows in a
///    list train the eye to ignore red exactly where it must not be ignored.
///
/// Every text/background pair below is asserted at ≥ 4.5:1 by
/// `test/contrast_test.dart`, so this cannot silently regress.
@immutable
class AppPalette extends ThemeExtension<AppPalette> {
  const AppPalette({
    required this.brightness,
    required this.canvas,
    required this.surface,
    required this.surfaceRaised,
    required this.border,
    required this.textBright,
    required this.textDim,
    required this.textTertiary,
    required this.accent,
    required this.accentInk,
    required this.danger,
    required this.dangerInk,
    required this.positive,
    required this.positiveInk,
    required this.peak,
    required this.onAccent,
  });

  final Brightness brightness;

  /// App background.
  final Color canvas;

  /// Raised surfaces: cards, sheets, dialogs.
  final Color surface;

  /// A second step above [surface] — sheets stacked over cards, menus, tooltips.
  final Color surfaceRaised;

  /// Hairline borders / dividers.
  final Color border;

  /// Primary text.
  final Color textBright;

  /// Secondary text: labels, captions, units.
  final Color textDim;

  /// Tertiary text: 12sp labels and axis ticks only. Sits at the AA floor —
  /// never use it below 12sp, and never for anything a rider must read in motion.
  final Color textTertiary;

  /// Amber — brand accent used as a *fill* (buttons, markers, badges).
  final Color accent;

  /// Legible amber for text/icons/lines on [canvas]/[surface].
  final Color accentInk;

  /// Red — used as a *fill* (STOP, destructive actions).
  final Color danger;

  /// Legible red for destructive text/lines.
  final Color dangerInk;

  /// Teal — improvement, moving, "better than last time". A *fill*.
  final Color positive;

  /// Legible teal for positive text/lines.
  final Color positiveInk;

  /// Peak / max values. Deliberately neutral: red is reserved for irreversible
  /// actions, so a max-speed readout must not borrow its alarm.
  final Color peak;

  /// Text/icon colour placed on top of [accent]/[danger]/[positive] fills.
  final Color onAccent;

  bool get isDark => brightness == Brightness.dark;

  static const dark = AppPalette(
    brightness: Brightness.dark,
    canvas: Color(0xFF121212), // app background (prototype frame)
    surface: Color(0xFF1E1E1E), // cards / sheets
    surfaceRaised: Color(0xFF232327),
    border: Color(0xFF303034), // #262626 was ~1.03:1 on surfaceRaised — invisible
    textBright: Color(0xFFF2F2F0),
    textDim: Color(0xFF9A9A9A),
    textTertiary: Color(0xFF8A8A8A),
    accent: Color(0xFFFFB22C),
    accentInk: Color(0xFFFFB22C), // amber reads fine as text on near-black
    danger: Color(0xFFEF4444),
    dangerInk: Color(0xFFFF6B6B), // #EF4444 only reaches 4.4:1 on `surface`
    positive: Color(0xFF5FE3C4),
    positiveInk: Color(0xFF5FE3C4),
    peak: Color(0xFFE8E4DC), // warm near-white — was danger red
    onAccent: Color(0xFF1A1200), // near-black ink on amber fills
  );

  static const light = AppPalette(
    brightness: Brightness.light,
    canvas: Color(0xFFFAFAF7),
    surface: Color(0xFFFFFFFF),
    surfaceRaised: Color(0xFFFFFFFF), // white is the ceiling; [border] elevates
    border: Color(0xFFE2E2DE), // #ECECEC barely separated canvas from card
    textBright: Color(0xFF1A1A1A),
    textDim: Color(0xFF6E6E6E),
    textTertiary: Color(0xFF737373),
    accent: Color(0xFFFFB22C),
    accentInk: Color(0xFF965D00), // deep amber — 5.4:1 on white (was 3.9:1)
    danger: Color(0xFFEF4444),
    dangerInk: Color(0xFFC92A2A),
    positive: Color(0xFF5FE3C4),
    positiveInk: Color(0xFF0E7C63),
    peak: Color(0xFF2B2620), // warm near-black — was danger red
    onAccent: Color(0xFF1A1200),
  );

  @override
  AppPalette copyWith({
    Brightness? brightness,
    Color? canvas,
    Color? surface,
    Color? surfaceRaised,
    Color? border,
    Color? textBright,
    Color? textDim,
    Color? textTertiary,
    Color? accent,
    Color? accentInk,
    Color? danger,
    Color? dangerInk,
    Color? positive,
    Color? positiveInk,
    Color? peak,
    Color? onAccent,
  }) {
    return AppPalette(
      brightness: brightness ?? this.brightness,
      canvas: canvas ?? this.canvas,
      surface: surface ?? this.surface,
      surfaceRaised: surfaceRaised ?? this.surfaceRaised,
      border: border ?? this.border,
      textBright: textBright ?? this.textBright,
      textDim: textDim ?? this.textDim,
      textTertiary: textTertiary ?? this.textTertiary,
      accent: accent ?? this.accent,
      accentInk: accentInk ?? this.accentInk,
      danger: danger ?? this.danger,
      dangerInk: dangerInk ?? this.dangerInk,
      positive: positive ?? this.positive,
      positiveInk: positiveInk ?? this.positiveInk,
      peak: peak ?? this.peak,
      onAccent: onAccent ?? this.onAccent,
    );
  }

  @override
  AppPalette lerp(ThemeExtension<AppPalette>? other, double t) {
    if (other is! AppPalette) return this;
    return AppPalette(
      brightness: t < 0.5 ? brightness : other.brightness,
      canvas: Color.lerp(canvas, other.canvas, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceRaised: Color.lerp(surfaceRaised, other.surfaceRaised, t)!,
      border: Color.lerp(border, other.border, t)!,
      textBright: Color.lerp(textBright, other.textBright, t)!,
      textDim: Color.lerp(textDim, other.textDim, t)!,
      textTertiary: Color.lerp(textTertiary, other.textTertiary, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      accentInk: Color.lerp(accentInk, other.accentInk, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      dangerInk: Color.lerp(dangerInk, other.dangerInk, t)!,
      positive: Color.lerp(positive, other.positive, t)!,
      positiveInk: Color.lerp(positiveInk, other.positiveInk, t)!,
      peak: Color.lerp(peak, other.peak, t)!,
      onAccent: Color.lerp(onAccent, other.onAccent, t)!,
    );
  }
}

/// Palette accessor for widgets: `final cx = AppColors.of(context);`.
///
/// Falls back to the dark palette if the extension is somehow absent (e.g. a
/// widget built outside the app theme).
class AppColors {
  AppColors._();

  static AppPalette of(BuildContext context) =>
      Theme.of(context).extension<AppPalette>() ?? AppPalette.dark;
}

/// Tabular (monospaced) digits. Without this every live readout re-flows as its
/// digits change — a speed jittering between "8" and "1" widths is measurably
/// harder to read on a moving handlebar. Apply to *any* number that updates.
const List<FontFeature> kTabularFigures = <FontFeature>[
  FontFeature.tabularFigures(),
];

/// Smallest type the app is allowed to render. The audit found 8–9sp unit
/// labels; below 12sp nothing survives sunlight at arm's length.
const double kMinFontSize = 12;

ThemeData buildLightTheme() => _themeFrom(AppPalette.light);
ThemeData buildDarkTheme() => _themeFrom(AppPalette.dark);

/// The app's type scale, as an *overlay* on Material's defaults.
///
/// Only the six roles the design actually specifies are pinned here; the rest
/// of the `TextTheme` is left to Material, because widgets like `ListTile` and
/// `TextButton` dereference roles (`bodyLarge`, `labelLarge`, `titleLarge`)
/// with a bang and would crash on a wholesale replacement.
///
/// Inter is bundled as an asset (see pubspec) so it renders offline from first
/// launch; it already carries a `tnum` table, so [kTabularFigures] works
/// without pulling in a second font family.
TextTheme _applyTypeScale(TextTheme base, AppPalette p) {
  return base.copyWith(
    // Live speed. The one number read in motion.
    displayLarge: TextStyle(
      fontFamily: 'Inter',
      fontSize: 64,
      height: 1.0,
      fontWeight: FontWeight.w600,
      letterSpacing: -1.5,
      fontFeatures: kTabularFigures,
      color: p.textBright,
    ),
    // Hero stat — the distance on a summary or detail screen.
    displayMedium: TextStyle(
      fontFamily: 'Inter',
      fontSize: 34,
      height: 1.05,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.8,
      fontFeatures: kTabularFigures,
      color: p.textBright,
    ),
    // Supporting stat values.
    headlineSmall: TextStyle(
      fontFamily: 'Inter',
      fontSize: 20,
      height: 1.1,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.2,
      fontFeatures: kTabularFigures,
      color: p.textBright,
    ),
    // Ride / trip titles.
    titleMedium: TextStyle(
      fontFamily: 'Inter',
      fontSize: 15,
      height: 1.25,
      fontWeight: FontWeight.w600,
      color: p.textBright,
    ),
    // Dates, routes, prose. Stays `textBright`: this is also the default style
    // for a bare `Text()` inside a Material, so dimming it here would quietly
    // grey out every unstyled string in the app.
    bodyMedium: TextStyle(
      fontFamily: 'Inter',
      fontSize: 13,
      height: 1.35,
      color: p.textBright,
    ),
    // All-caps stat labels. The 12sp floor lives here.
    labelSmall: TextStyle(
      fontFamily: 'Inter',
      fontSize: kMinFontSize,
      height: 1.2,
      fontWeight: FontWeight.w500,
      letterSpacing: 1.0,
      color: p.textTertiary,
    ),
  );
}

/// App-wide theme built from a palette.
ThemeData _themeFrom(AppPalette p) {
  final base = ThemeData(useMaterial3: true, brightness: p.brightness);

  // Built field-by-field rather than from a stock ColorScheme.dark()/light():
  // the leftover Material defaults (notably `primary`'s lavender) were tinting
  // app bars and dialogs straight through the palette.
  final scheme = ColorScheme(
    brightness: p.brightness,
    primary: p.accentInk,
    onPrimary: p.onAccent,
    primaryContainer: p.accent,
    onPrimaryContainer: p.onAccent,
    secondary: p.accentInk,
    onSecondary: p.onAccent,
    surface: p.surface,
    onSurface: p.textBright,
    surfaceContainerHighest: p.surfaceRaised,
    onSurfaceVariant: p.textDim,
    surfaceTint: Colors.transparent,
    outline: p.border,
    outlineVariant: p.border,
    error: p.danger,
    onError: p.onAccent,
    errorContainer: p.danger,
    onErrorContainer: p.onAccent,
    shadow: const Color(0xFF000000),
    scrim: const Color(0xFF000000),
    inverseSurface: p.textBright,
    onInverseSurface: p.canvas,
    inversePrimary: p.accent,
  );

  // Inter + palette colours go on to *all* of Material's roles first, then the
  // design's six roles are layered on top. Doing it in this order keeps roles
  // the design never mentions (labelLarge on buttons, bodyLarge on list tiles)
  // populated instead of null.
  final text = _applyTypeScale(
    base.textTheme.apply(
      fontFamily: 'Inter',
      bodyColor: p.textBright,
      displayColor: p.textBright,
    ),
    p,
  );

  return base.copyWith(
    scaffoldBackgroundColor: p.canvas,
    canvasColor: p.canvas,
    colorScheme: scheme,
    extensions: [p],
    textTheme: text,
    // Material 3 tints every elevated surface with `surfaceTint` (which
    // defaulted to the scheme's lavender primary) — that, plus the absence of an
    // AppBarTheme, is what turned the light app bar lavender. Tint is killed
    // globally here; elevation is expressed with `border` instead.
    appBarTheme: AppBarTheme(
      backgroundColor: p.canvas,
      foregroundColor: p.textBright,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      iconTheme: IconThemeData(color: p.textBright),
      actionsIconTheme: IconThemeData(color: p.textBright),
      titleTextStyle: text.titleMedium!.copyWith(fontSize: 18),
    ),
    cardTheme: CardThemeData(
      color: p.surface,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      elevation: 0,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.surfaceRaised,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: text.titleMedium!.copyWith(fontSize: 18),
      contentTextStyle: text.bodyMedium!.copyWith(fontSize: 14),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: p.surfaceRaised,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: p.surfaceRaised,
      surfaceTintColor: Colors.transparent,
      textStyle: text.bodyMedium!.copyWith(fontSize: 14, color: p.textBright),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: p.surfaceRaised,
      contentTextStyle: text.bodyMedium!.copyWith(fontSize: 14),
    ),
    // Colour and weight only — leaving `space` to Material so a future bare
    // `Divider()` keeps its normal vertical padding.
    dividerTheme: DividerThemeData(color: p.border, thickness: 1),
    iconTheme: IconThemeData(color: p.textBright),
    listTileTheme: ListTileThemeData(
      textColor: p.textBright,
      iconColor: p.textDim,
    ),
  );
}
