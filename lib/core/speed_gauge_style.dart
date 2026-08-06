/// How the Record screen renders the live speed.
///
/// [digital] is the original big numeral — cheapest to draw and the easiest to
/// read at a glance. [analog] swaps it for a half-moon arc gauge (the needle and
/// the sweep give speed a *shape*, so a glance reads "roughly two thirds" without
/// parsing digits) with the numeral kept in the middle.
///
/// The choice is persisted (see `SettingsService.saveSpeedGaugeStyle`).
enum SpeedGaugeStyle {
  digital,
  analog;

  /// Short stable tag persisted in settings.
  String get tag => switch (this) {
        SpeedGaugeStyle.digital => 'digital',
        SpeedGaugeStyle.analog => 'analog',
      };

  static SpeedGaugeStyle fromTag(String? tag) => switch (tag) {
        'analog' => SpeedGaugeStyle.analog,
        _ => SpeedGaugeStyle.digital,
      };

  /// Human label, used by the Settings row and spoken by both surfaces.
  ///
  /// "Dial" / "Number" rather than "Analog" / "Digital": the rider is picking a
  /// shape, not a technology.
  String get label => switch (this) {
        SpeedGaugeStyle.digital => 'Number',
        SpeedGaugeStyle.analog => 'Dial',
      };

  /// The compact form for the Record screen's toolbar row, where this sits beside
  /// four glyphs and has to cost about as little width as they do.
  ///
  /// Lives here rather than in the widget so the two surfaces still have exactly
  /// one place that decides what these styles are called — the long form and the
  /// short form of one name, not two names.
  String get shortLabel => switch (this) {
        SpeedGaugeStyle.digital => '123',
        SpeedGaugeStyle.analog => 'Dial',
      };

  /// The other style — the Settings row is a straight toggle.
  SpeedGaugeStyle get next => switch (this) {
        SpeedGaugeStyle.digital => SpeedGaugeStyle.analog,
        SpeedGaugeStyle.analog => SpeedGaugeStyle.digital,
      };
}
