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

  /// Human label, shared by the Record-screen switcher and its Settings mirror.
  ///
  /// "Dial" / "Number" rather than "Analog" / "Digital": the rider is picking a
  /// shape, not a technology, and the shorter words fit a segmented control.
  String get label => switch (this) {
        SpeedGaugeStyle.digital => 'Number',
        SpeedGaugeStyle.analog => 'Dial',
      };

  /// The other style — the Settings row is a straight toggle.
  SpeedGaugeStyle get next => switch (this) {
        SpeedGaugeStyle.digital => SpeedGaugeStyle.analog,
        SpeedGaugeStyle.analog => SpeedGaugeStyle.digital,
      };
}
