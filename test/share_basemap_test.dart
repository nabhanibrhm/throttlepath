import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:throttlepath/services/carto_watermark.dart';
import 'package:throttlepath/services/share_basemap.dart';

/// The share card's basemap is the one part of the card that talks to the
/// outside world, and the one whose failure mode is silent: a crop computed a
/// zoom level off still returns tiles, still draws, and just shows the wrong
/// place. So the maths is tested directly rather than through a render.
///
/// The fetcher is injected throughout — no network, no device cache. That seam
/// exists because the geocoding work shipped without one and is device-verified
/// only; this is the same shape of code and should not repeat it.

/// A 1x1 transparent PNG. Enough to decode; the pixels are never asserted on.
final _pngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk'
  'YPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

/// Records what was asked for, and answers everything.
class _FakeTiles {
  final urls = <String>[];

  Future<Uint8List?> call(String url) async {
    urls.add(url);
    return _pngBytes;
  }
}

/// An in-memory [MapCachingProvider]; records writes so a test can assert that
/// a placeholder never reached the cache.
class _FakeCache implements MapCachingProvider {
  final tiles = <String, ({Uint8List bytes, String? etag})>{};
  final puts = <String>[];

  @override
  bool get isSupported => true;

  @override
  Future<CachedMapTile?> getTile(String url) async {
    final t = tiles[url];
    if (t == null) return null;
    return (
      bytes: t.bytes,
      metadata: CachedMapTileMetadata(
        staleAt: DateTime.now().add(const Duration(days: 1)),
        lastModified: null,
        etag: t.etag,
      ),
    );
  }

  @override
  Future<void> putTile({
    required String url,
    required CachedMapTileMetadata metadata,
    Uint8List? bytes,
  }) async {
    puts.add(url);
  }
}

/// A ride around Bekasi, roughly 3km across.
List<LatLng> _ride({int n = 40, double spread = 0.015}) => [
      for (var i = 0; i < n; i++)
        LatLng(-6.24 + spread * i / n, 106.99 + spread * 0.7 * i / n),
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const template = 'https://{s}.example/{z}/{x}/{y}.png';

  group('tile URLs', () {
    test('fill every placeholder and cycle the subdomains', () {
      final a = ShareBasemapLoader.tileUrl(template, const ['a', 'b'], 3, 4, 5, 0);
      final b = ShareBasemapLoader.tileUrl(template, const ['a', 'b'], 3, 4, 5, 1);
      expect(a, 'https://a.example/5/3/4.png');
      expect(b, 'https://b.example/5/3/4.png');
    });

    test('a template with no subdomains left in it still resolves', () {
      expect(
        ShareBasemapLoader.tileUrl(
            'https://tiles/{z}/{x}/{y}.png', const [], 1, 2, 3, 0),
        'https://tiles/3/1/2.png',
      );
    });
  });

  group('the tile range', () {
    test('covers the crop and nothing beyond it', () {
      // Exactly two tiles wide and one tall, offset into the grid.
      final crop = Rect.fromLTWH(512, 256, 512, 256);
      expect(ShareBasemapLoader.tileRange(crop, 10),
          (left: 2, top: 1, right: 3, bottom: 1));
      expect(ShareBasemapLoader.tileCount(crop, 10), 2);
    });

    test('a crop ending on a tile boundary does not pull in the next tile', () {
      // The off-by-one that costs a 5x5 grid ten wasted fetches: the crop's
      // right edge is the first pixel of tile 2, which it does not need.
      final crop = Rect.fromLTWH(0, 0, 512, 512);
      expect(ShareBasemapLoader.tileCount(crop, 10), 4);
    });

    test('clamps to the world rather than asking for a negative tile', () {
      // Zoom 2 is a 4x4 world. A crop hanging off the top-left must not index
      // tile (-1, -1) — the server answers 404 and the map loses a corner.
      final crop = Rect.fromLTWH(-300, -300, 400, 400);
      final range = ShareBasemapLoader.tileRange(crop, 2);
      expect(range.left, 0);
      expect(range.top, 0);
    });
  });

  group('the crop', () {
    test('contains the whole ride with a margin', () {
      final route = _ride();
      final crop = ShareBasemapLoader.cropFor(route, 14);
      for (final p in route) {
        final o = const ShareBasemap(zoom: 14, crop: Rect.zero, tiles: [])
            .worldOf(p.latitude, p.longitude);
        expect(crop.contains(o), isTrue,
            reason: 'a fix fell outside the map the card will draw');
      }
    });

    test('a dead-straight ride is widened instead of drawn as a ribbon', () {
      // Due north, so the bounding box has effectively no width. Cropping to it
      // literally would give a map a few pixels across.
      final northSouth = [
        for (var i = 0; i < 20; i++) LatLng(-6.24 + 0.02 * i / 20, 106.99),
      ];
      final crop = ShareBasemapLoader.cropFor(northSouth, 14);
      expect(crop.height / crop.width, lessThanOrEqualTo(3.01),
          reason: 'the crop stayed more extreme than the 3:1 clamp');
    });

    test('a tiny ride is pulled back rather than magnified', () {
      // A lap of a car park. Cropping tight would upscale a 60px map into the
      // route box; the floor pulls the camera back instead.
      final lap = [
        for (var i = 0; i < 10; i++)
          LatLng(-6.24 + 0.00008 * i, 106.99 + 0.00008 * i),
      ];
      final crop = ShareBasemapLoader.cropFor(lap, 18);
      expect(crop.width, greaterThanOrEqualTo(384));
      expect(crop.height, greaterThanOrEqualTo(384));
    });
  });

  group('loading', () {
    test('a ride resolves to a grid of tiles inside the budget', () async {
      final fake = _FakeTiles();
      final map = await ShareBasemapLoader.load(
        route: _ride(),
        urlTemplate: template,
        fetch: fake.call,
      );

      expect(map, isNotNull);
      expect(map!.tiles, isNotEmpty);
      expect(fake.urls, hasLength(map.tiles.length));
      expect(map.tiles.length, lessThanOrEqualTo(30),
          reason: 'a single card fetched more than its tile budget');
      // Every tile the card holds is one it will actually draw.
      for (final tile in map.tiles) {
        expect(tile.world.overlaps(map.crop), isTrue);
      }
      map.dispose();
    });

    test('a 470km trip drops zoom rather than blowing the budget', () async {
      // The Ujung Genteng trip's shape: hundreds of km end to end. At the zoom a
      // short ride gets, this would be thousands of tiles.
      final long = [
        for (var i = 0; i < 60; i++)
          LatLng(-6.24 - 2.0 * i / 60, 106.99 - 1.4 * i / 60),
      ];
      final fake = _FakeTiles();
      final map = await ShareBasemapLoader.load(
        route: long,
        urlTemplate: template,
        fetch: fake.call,
      );

      expect(map, isNotNull);
      expect(map!.tiles.length, lessThanOrEqualTo(30));
      expect(map.zoom, lessThan(14),
          reason: 'a trip spanning two degrees was fetched at street zoom');
      map.dispose();
    });

    test('no tiles means no basemap, not a failed share', () async {
      // The offline case the silent-fallback decision is about: nothing cached,
      // no signal. The card must come back null and render as it always has.
      final map = await ShareBasemapLoader.load(
        route: _ride(),
        urlTemplate: template,
        fetch: (_) async => null,
      );
      expect(map, isNull);
    });

    test('a partly answered grid still gives a map', () async {
      // Some tiles cached, some not, no signal for the rest. Better a map with
      // a hole than no map — and it must not throw on the way.
      var n = 0;
      final map = await ShareBasemapLoader.load(
        route: _ride(),
        urlTemplate: template,
        fetch: (_) async {
          final even = n.isEven;
          n++;
          return even ? _pngBytes : null;
        },
      );
      expect(map, isNotNull);
      expect(map!.tiles, isNotEmpty);
      map.dispose();
    });

    test('undecodable bytes are a hole in the map, not an exception', () async {
      final map = await ShareBasemapLoader.load(
        route: _ride(),
        urlTemplate: template,
        fetch: (_) async => Uint8List.fromList([1, 2, 3, 4]),
      );
      expect(map, isNull);
    });

    test('an empty route asks for nothing', () async {
      final fake = _FakeTiles();
      final map = await ShareBasemapLoader.load(
        route: const [],
        urlTemplate: template,
        fetch: fake.call,
      );
      expect(map, isNull);
      expect(fake.urls, isEmpty);
    });
  });

  group('CARTO watermark tiles', () {
    // Fetched once with curl from a keyless request (see carto_watermark.dart for
    // the evidence). The real tile is an open-ocean one: 103 bytes, smaller than
    // either placeholder, which is why size is not the test.
    final dark =
        File('test/fixtures/carto_watermark_dark.png').readAsBytesSync();
    final light =
        File('test/fixtures/carto_watermark_light.png').readAsBytesSync();
    final ocean =
        File('test/fixtures/carto_real_ocean_tile.png').readAsBytesSync();

    test('the embedded placeholders are the fixtures, byte for byte', () {
      expect(isWatermarkBytes(dark), isTrue);
      expect(isWatermarkBytes(light), isTrue);
    });

    test('a real tile is not a watermark, however small', () {
      expect(ocean.length, lessThan(dark.length));
      expect(isWatermarkBytes(ocean), isFalse);
      expect(isCartoWatermark(ocean, etag: '"martin-20261001-02"'), isFalse);
      expect(isCartoWatermark(_pngBytes), isFalse);
    });

    test('a watermark with one byte changed is not matched', () {
      // Equality is exact on purpose: only the placeholder itself is rejected.
      final tweaked = Uint8List.fromList(dark)..[dark.length - 1] ^= 1;
      expect(isWatermarkBytes(tweaked), isFalse);
    });

    test('the wm- ETag is recognised in the shapes a cache may hand back', () {
      expect(isWatermarkEtag('"wm-da89c20e77c1-dark"'), isTrue);
      expect(isWatermarkEtag('wm-da89c20e77c1-light'), isTrue);
      expect(isWatermarkEtag('W/"wm-da89c20e77c1-dark"'), isTrue);
      expect(isWatermarkEtag('"martin-20261001-02"'), isFalse);
      expect(isWatermarkEtag(null), isFalse);
      expect(isWatermarkEtag(''), isFalse);
    });

    test('the ETag alone condemns a tile even if the bytes are unfamiliar', () {
      // CARTO redrawing the placeholder must not defeat the header check.
      expect(isCartoWatermark(_pngBytes, etag: '"wm-newdesign-dark"'), isTrue);
    });

    test('a watermark from the fetcher is a missing tile', () async {
      final map = await ShareBasemapLoader.load(
        route: _ride(),
        urlTemplate: template,
        fetch: (_) async => dark,
      );
      expect(map, isNull,
          reason: 'a placeholder was drawn onto the share card');
    });

    test('partial coverage keeps the real tiles and drops the watermarks',
        () async {
      // Same policy as any other missing tile: the grid keeps what it has and
      // the rest is transparent. Alternate real / watermark across the grid.
      var n = 0;
      final map = await ShareBasemapLoader.load(
        route: _ride(),
        urlTemplate: template,
        fetch: (_) async {
          final real = n.isEven;
          n++;
          return real ? _pngBytes : light;
        },
      );
      expect(map, isNotNull);
      expect(map!.tiles.length, (n / 2).ceil());
      map.dispose();
    });

    group('cacheThenNetwork', () {
      late HttpServer server;
      late List<String> served;
      late _FakeCache cache;

      void serve({required Uint8List body, String? etag}) {
        server.listen((req) {
          served.add(req.uri.path);
          if (etag != null) req.response.headers.set('etag', etag);
          req.response.add(body);
          req.response.close();
        });
      }

      String url() =>
          'http://${server.address.host}:${server.port}/dark_all/12/3270/2118.png';

      Future<void> settle() =>
          Future<void>.delayed(const Duration(milliseconds: 50));

      setUp(() async {
        // TestWidgetsFlutterBinding swaps in an HttpClient that answers 400 to
        // everything; this needs the real one, pointed at loopback.
        HttpOverrides.global = null;
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        served = [];
        cache = _FakeCache();
      });
      tearDown(() async => server.close(force: true));

      test('a watermark from the network is neither returned nor cached',
          () async {
        serve(body: dark, etag: '"wm-da89c20e77c1-dark"');
        final got =
            await ShareBasemapLoader.cacheThenNetwork(url(), cache: cache);
        expect(got, isNull);
        expect(served, hasLength(1));
        await settle();
        expect(cache.puts, isEmpty);
      });

      test('a watermark with no ETag is caught by its bytes', () async {
        serve(body: light);
        final got =
            await ShareBasemapLoader.cacheThenNetwork(url(), cache: cache);
        expect(got, isNull);
        await settle();
        expect(cache.puts, isEmpty);
      });

      test('a real tile from the network is returned and cached', () async {
        serve(body: ocean, etag: '"martin-20261001-02"');
        final got =
            await ShareBasemapLoader.cacheThenNetwork(url(), cache: cache);
        expect(got, ocean);
        await settle();
        expect(cache.puts, [url()]);
      });

      test('a watermark already in the cache is skipped, not served', () async {
        // The phone's legacy case: keyless placeholders cached under old URLs.
        cache.tiles[url()] = (bytes: dark, etag: '"wm-da89c20e77c1-dark"');
        serve(body: dark, etag: '"wm-da89c20e77c1-dark"');
        final got =
            await ShareBasemapLoader.cacheThenNetwork(url(), cache: cache);
        expect(got, isNull);
        expect(served, hasLength(1), reason: 'a cached watermark is a miss');
        await settle();
        expect(cache.puts, isEmpty);
      });

      test('a cached watermark is spotted by bytes when its ETag is gone',
          () async {
        cache.tiles[url()] = (bytes: light, etag: null);
        serve(body: ocean);
        final got =
            await ShareBasemapLoader.cacheThenNetwork(url(), cache: cache);
        expect(got, ocean, reason: 'the real tile should replace the bad entry');
      });

      test('a real cached tile is served without touching the network',
          () async {
        cache.tiles[url()] = (bytes: ocean, etag: '"martin-20261001-02"');
        serve(body: dark);
        final got =
            await ShareBasemapLoader.cacheThenNetwork(url(), cache: cache);
        expect(got, ocean);
        expect(served, isEmpty);
      });
    });
  });
}
