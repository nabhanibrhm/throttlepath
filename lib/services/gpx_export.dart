import '../data/models/ride.dart';
import '../data/models/track_point.dart';
import 'share_channel.dart';

/// Writes a ride (or a whole trip) out as GPX 1.1 and hands it to the system
/// share sheet.
///
/// GPX is the one format every mapping tool reads, and it is the only way a ride
/// recorded here leaves the phone as *data* rather than as a picture — the share
/// card is lovely and completely unusable in another app.
class GpxExport {
  GpxExport._();

  /// GPX timestamps are UTC, ISO 8601, with a `Z`.
  static String _isoUtc(DateTime t) =>
      '${t.toUtc().toIso8601String().split('.').first}Z';

  /// Escapes the five XML predefined entities. Ride names are user input and go
  /// straight into `<name>`, so an ampersand in "Bandung & back" must not produce
  /// a file no parser will open.
  static String xmlEscape(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');

  /// Serialises [points] as a GPX document.
  ///
  /// [stintStarts] marks the index in [points] where each stint after the first
  /// begins; each stint becomes its own `<trkseg>`, which is exactly what segments
  /// mean in GPX — a break in recording, not a break in the journey. A
  /// single-ride export passes an empty list and gets one segment.
  ///
  /// Pure string building, so it is unit-testable without a device.
  static String buildGpx({
    required Ride ride,
    required List<TrackPoint> points,
    List<int> stintStarts = const [],
  }) {
    final trimmed = ride.name?.trim();
    final name =
        xmlEscape(trimmed != null && trimmed.isNotEmpty ? trimmed : 'Ride');
    final b = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
      ..writeln('<gpx version="1.1" creator="ThrottlePath" '
          'xmlns="http://www.topografix.com/GPX/1/1">')
      ..writeln('  <metadata>')
      ..writeln('    <name>$name</name>')
      ..writeln('    <time>${_isoUtc(ride.startTime)}</time>')
      ..writeln('  </metadata>')
      ..writeln('  <trk>')
      ..writeln('    <name>$name</name>')
      ..writeln('    <type>motorcycling</type>');

    // Segment boundaries, deduplicated and in order: a stint start of 0 is implied
    // by the first segment, and an out-of-range one would produce an empty seg.
    final breaks = stintStarts
        .where((i) => i > 0 && i < points.length)
        .toSet()
        .toList()
      ..sort();
    final bounds = [0, ...breaks, points.length];

    for (var s = 0; s < bounds.length - 1; s++) {
      final from = bounds[s];
      final to = bounds[s + 1];
      if (to <= from) continue;
      b.writeln('    <trkseg>');
      for (var i = from; i < to; i++) {
        final p = points[i];
        b.writeln('      <trkpt lat="${p.latitude.toStringAsFixed(7)}" '
            'lon="${p.longitude.toStringAsFixed(7)}">');
        if (p.altitude != null) {
          b.writeln('        <ele>${p.altitude!.toStringAsFixed(1)}</ele>');
        }
        b.writeln('        <time>${_isoUtc(p.timestamp)}</time>');
        // Ground speed belongs in an extension in GPX 1.1 (1.0 had <speed> on
        // trkpt; 1.1 dropped it), and it is what makes a re-imported track
        // reproduce this app's own speed numbers instead of re-deriving them.
        b
          ..writeln('        <extensions>')
          ..writeln('          <speed>${p.speedMps.toStringAsFixed(2)}</speed>')
          ..writeln('        </extensions>')
          ..writeln('      </trkpt>');
      }
      b.writeln('    </trkseg>');
    }

    b
      ..writeln('  </trk>')
      ..writeln('</gpx>');
    return b.toString();
  }

  /// A filesystem-safe basename like `throttlepath-morning-commute-20260728.gpx`.
  static String fileNameFor(Ride ride) {
    final raw = (ride.name ?? '').trim().toLowerCase();
    final slug = raw
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    final d = ride.startTime.toLocal();
    final stamp = '${d.year}'
        '${d.month.toString().padLeft(2, '0')}'
        '${d.day.toString().padLeft(2, '0')}';
    final middle = slug.isEmpty ? 'ride' : slug;
    return 'throttlepath-$middle-$stamp.gpx';
  }

  /// Writes the GPX to the app's private cache (the folder FileProvider is scoped
  /// to) and opens the system share sheet on it.
  ///
  /// Throws on a write or platform failure; callers surface a message.
  static Future<void> share({
    required Ride ride,
    required List<TrackPoint> points,
    List<int> stintStarts = const [],
  }) async {
    if (points.isEmpty) {
      throw StateError('Nothing to export — this ride has no recorded track.');
    }
    final name = ride.name?.trim();
    await ShareChannel.shareTextFile(
      fileName: fileNameFor(ride),
      contents: buildGpx(ride: ride, points: points, stintStarts: stintStarts),
      mimeType: 'application/gpx+xml',
      title: name != null && name.isNotEmpty ? name : 'ThrottlePath ride',
    );
  }
}
