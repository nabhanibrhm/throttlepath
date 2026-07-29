/// What the Record screen shows behind the telemetry sheet.
///
/// The live map and its per-frame blur are the dominant on-screen power draw,
/// so the rider can trade it for a lightweight live speed/distance chart, or
/// hide both entirely (a static branded backdrop) to let the GPU idle and the
/// screen sleep while recording continues in the background service.
///
/// The Record screen's toggle cycles [map] → [chart] → [lean] → [none] → [map];
/// the choice is persisted (see `SettingsService.saveRecordView`).
enum RecordView {
  map,
  chart,
  lean,
  none;

  /// Short stable tag persisted in settings.
  String get tag => switch (this) {
        RecordView.map => 'map',
        RecordView.chart => 'chart',
        RecordView.lean => 'lean',
        RecordView.none => 'none',
      };

  /// Human label, shared by the Record-screen switcher and its Settings mirror
  /// so the two can never drift apart.
  String get label => switch (this) {
        RecordView.map => 'Map',
        RecordView.chart => 'Chart',
        RecordView.lean => 'Lean',
        RecordView.none => 'Off',
      };

  static RecordView fromTag(String? tag) => switch (tag) {
        'map' => RecordView.map,
        'chart' => RecordView.chart,
        'lean' => RecordView.lean,
        _ => RecordView.none,
      };

  /// The next view in the cycle map → chart → lean → none → map.
  RecordView get next => switch (this) {
        RecordView.map => RecordView.chart,
        RecordView.chart => RecordView.lean,
        RecordView.lean => RecordView.none,
        RecordView.none => RecordView.map,
      };
}
