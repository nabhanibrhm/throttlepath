import 'package:flutter_test/flutter_test.dart';
import 'package:throttlepath/data/models/ride.dart';
import 'package:throttlepath/data/models/track_point.dart';
import 'package:throttlepath/services/gpx_export.dart';

/// Phase 4.9 — GPX is the one way a ride leaves the phone as data rather than as
/// a picture, so the document has to be well-formed for parsers we'll never see.
TrackPoint point(
  double lat,
  double lon, {
  double? altitude,
  double speedMps = 12.5,
  DateTime? at,
}) {
  return TrackPoint()
    ..rideId = 1
    ..latitude = lat
    ..longitude = lon
    ..altitude = altitude
    ..speedMps = speedMps
    ..timestamp = at ?? DateTime.utc(2026, 7, 28, 3, 15, 30);
}

Ride ride({String? name}) => Ride()
  ..id = 7
  ..name = name
  ..startTime = DateTime.utc(2026, 7, 28, 3, 0, 0)
  ..endTime = DateTime.utc(2026, 7, 28, 4, 0, 0);

void main() {
  group('xmlEscape', () {
    test('escapes all five predefined entities', () {
      expect(
        GpxExport.xmlEscape('''a & b < c > d " e ' f'''),
        'a &amp; b &lt; c &gt; d &quot; e &apos; f',
      );
    });

    test('escapes the ampersand before the entities it introduces', () {
      // Naive ordering yields &amp;lt; here — a file no parser opens.
      expect(GpxExport.xmlEscape('&lt;'), '&amp;lt;');
    });
  });

  group('buildGpx', () {
    test('emits a well-formed single-segment document', () {
      final gpx = GpxExport.buildGpx(
        ride: ride(name: 'Morning commute'),
        points: [point(-6.9147, 107.6098), point(-6.9130, 107.6075)],
      );
      expect(gpx, startsWith('<?xml version="1.0" encoding="UTF-8"?>'));
      expect(gpx, contains('<gpx version="1.1" creator="ThrottlePath"'));
      expect(gpx, contains('xmlns="http://www.topografix.com/GPX/1/1"'));
      expect(gpx.trim(), endsWith('</gpx>'));
      expect('<trkseg>'.allMatches(gpx).length, 1);
      expect('<trkpt'.allMatches(gpx).length, 2);
      expect(gpx, contains('<name>Morning commute</name>'));
    });

    test('timestamps are UTC with a Z and no fractional seconds', () {
      final gpx = GpxExport.buildGpx(
        ride: ride(),
        points: [point(1, 2, at: DateTime.utc(2026, 7, 28, 3, 15, 30, 456))],
      );
      expect(gpx, contains('<time>2026-07-28T03:15:30Z</time>'));
      expect(gpx, isNot(contains('.456')));
    });

    test('a name with an ampersand does not corrupt the document', () {
      final gpx =
          GpxExport.buildGpx(ride: ride(name: 'Bandung & back'), points: [point(1, 2)]);
      expect(gpx, contains('<name>Bandung &amp; back</name>'));
      expect(gpx, isNot(contains('Bandung & back')));
    });

    test('an unnamed ride still gets a name element', () {
      for (final n in [null, '', '   ']) {
        final gpx = GpxExport.buildGpx(ride: ride(name: n), points: [point(1, 2)]);
        expect(gpx, contains('<name>Ride</name>'), reason: 'for name "$n"');
      }
    });

    test('elevation appears only for fixes that reported one', () {
      final gpx = GpxExport.buildGpx(
        ride: ride(),
        points: [point(1, 2, altitude: 768.4), point(3, 4)],
      );
      expect('<ele>'.allMatches(gpx).length, 1);
      expect(gpx, contains('<ele>768.4</ele>'));
    });

    test('speed rides in an extension, as GPX 1.1 requires', () {
      // 1.0 allowed <speed> straight on trkpt; 1.1 dropped it.
      final gpx =
          GpxExport.buildGpx(ride: ride(), points: [point(1, 2, speedMps: 18.75)]);
      expect(gpx, contains('<extensions>'));
      expect(gpx, contains('<speed>18.75</speed>'));
    });

    group('trip stints', () {
      final points = [
        for (var i = 0; i < 6; i++) point(-6.9 + i * 0.001, 107.6),
      ];

      test('each stint becomes its own segment', () {
        final gpx = GpxExport.buildGpx(
          ride: ride(name: 'Weekend trip'),
          points: points,
          stintStarts: const [2, 4],
        );
        expect('<trkseg>'.allMatches(gpx).length, 3);
        expect('<trkpt'.allMatches(gpx).length, 6);
      });

      test('a leading zero is implied, not a second empty segment', () {
        final gpx = GpxExport.buildGpx(
            ride: ride(), points: points, stintStarts: const [0, 3]);
        expect('<trkseg>'.allMatches(gpx).length, 2);
      });

      test('duplicate and out-of-range boundaries are ignored', () {
        // Untrusted input: stintStarts is assembled by the caller from stint lengths.
        final gpx = GpxExport.buildGpx(
          ride: ride(),
          points: points,
          stintStarts: const [3, 3, 99, -1],
        );
        expect('<trkseg>'.allMatches(gpx).length, 2);
        expect('<trkpt'.allMatches(gpx).length, 6);
      });

      test('unsorted boundaries still produce segments in order', () {
        final gpx = GpxExport.buildGpx(
            ride: ride(), points: points, stintStarts: const [4, 2]);
        expect('<trkseg>'.allMatches(gpx).length, 3);
        expect('<trkpt'.allMatches(gpx).length, 6);
      });
    });

    test('no points still yields a parseable document', () {
      // The share path refuses to export an empty track, but the serialiser must
      // not produce broken XML if it is ever called with one.
      final gpx = GpxExport.buildGpx(ride: ride(), points: const []);
      expect(gpx, contains('</gpx>'));
      expect(gpx, isNot(contains('<trkseg>')));
    });
  });

  group('fileNameFor', () {
    // The date stamp is the ride's *local* day, so these build local start times
    // rather than reusing the UTC helper above — otherwise the expected filename
    // would depend on the machine's timezone.
    Ride local({String? name}) => Ride()
      ..id = 7
      ..name = name
      ..startTime = DateTime(2026, 7, 28, 10)
      ..endTime = DateTime(2026, 7, 28, 11);

    test('slugs the ride name and stamps the date', () {
      expect(
        GpxExport.fileNameFor(local(name: 'Morning Commute')),
        'throttlepath-morning-commute-20260728.gpx',
      );
    });

    test('strips punctuation instead of putting it in a filename', () {
      expect(
        GpxExport.fileNameFor(local(name: '  Bandung → Lembang!! ')),
        'throttlepath-bandung-lembang-20260728.gpx',
      );
    });

    test('a name with nothing usable in it falls back', () {
      for (final n in [null, '', '???', '   ']) {
        expect(
          GpxExport.fileNameFor(local(name: n)),
          'throttlepath-ride-20260728.gpx',
          reason: 'for name "$n"',
        );
      }
    });

    test('zero-pads single-digit months and days', () {
      final r = local()..startTime = DateTime(2026, 3, 5, 8);
      expect(GpxExport.fileNameFor(r), 'throttlepath-ride-20260305.gpx');
    });
  });
}
