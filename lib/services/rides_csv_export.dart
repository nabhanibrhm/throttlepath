import '../data/database_service.dart';
import '../data/models/ride.dart';
import 'share_channel.dart';

/// Exports the whole ride history as one CSV and hands it to the share sheet.
///
/// **Why CSV and not a folder of GPX.** GPX is per-ride and carries the track;
/// exporting thirty of them means either thirty share sheets or a zip, and
/// zipping needs a dependency the app does not have. This is the other half of
/// the job — one row per ride, every derived number the app holds, in the format
/// a spreadsheet opens by double-clicking. Per-ride GPX (with the actual fixes)
/// already ships from the ride summary and detail screens; the two are
/// complementary, not competing.
class RidesCsvExport {
  RidesCsvExport._();

  static const _headers = [
    'id',
    'name',
    'start_local',
    'end_local',
    'distance_m',
    'duration_s',
    'moving_s',
    'avg_speed_kmh',
    'max_speed_kmh',
    'start_place',
    'end_place',
    'trip_id',
    'route_key',
    'smoothness',
    'gps_source',
  ];

  /// Quotes a field when it contains a comma, a quote or a newline, doubling any
  /// embedded quotes (RFC 4180).
  ///
  /// Ride names are free text: "Bandung, then home" would otherwise become two
  /// columns and silently shift every field after it on that row.
  static String csvField(Object? value) {
    final s = value?.toString() ?? '';
    if (!s.contains(RegExp('[",\n\r]'))) return s;
    return '"${s.replaceAll('"', '""')}"';
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  /// Local time as `YYYY-MM-DD HH:MM:SS` — what a spreadsheet parses as a date
  /// without being told to.
  static String _stamp(DateTime? t) {
    if (t == null) return '';
    final d = t.toLocal();
    return '${d.year}-${_two(d.month)}-${_two(d.day)} '
        '${_two(d.hour)}:${_two(d.minute)}:${_two(d.second)}';
  }

  /// Builds the CSV document for [rides]. Pure, so it is testable without a DB.
  static String buildCsv(List<Ride> rides) {
    final b = StringBuffer()..writeln(_headers.join(','));
    for (final r in rides) {
      b.writeln([
        r.id,
        csvField(r.name),
        _stamp(r.startTime),
        _stamp(r.endTime),
        r.totalDistanceMeters.toStringAsFixed(1),
        r.durationSeconds,
        r.movingSeconds,
        r.averageSpeedKmh.toStringAsFixed(2),
        r.maxSpeedKmh.toStringAsFixed(2),
        csvField(r.startPlace),
        csvField(r.endPlace),
        r.tripId ?? '',
        csvField(r.routeKey),
        r.smoothness?.toStringAsFixed(1) ?? '',
        csvField(r.gpsSource),
      ].join(','));
    }
    return b.toString();
  }

  static String fileNameFor(DateTime now) {
    final d = now.toLocal();
    return 'throttlepath-rides-${d.year}${_two(d.month)}${_two(d.day)}.csv';
  }

  /// Writes every finished ride to a CSV in the shareable cache folder and opens
  /// the system share sheet. Returns how many rides were written.
  ///
  /// Throws on an empty history or a platform failure; the caller surfaces it.
  static Future<int> shareAll({DateTime? now}) async {
    final rides = await DatabaseService.instance.getAllRides();
    final finished = [for (final r in rides) if (r.endTime != null) r];
    if (finished.isEmpty) {
      throw StateError('No finished rides to export yet.');
    }

    await ShareChannel.shareTextFile(
      fileName: fileNameFor(now ?? DateTime.now()),
      contents: buildCsv(finished),
      mimeType: 'text/csv',
      title: 'ThrottlePath rides',
    );
    return finished.length;
  }
}
