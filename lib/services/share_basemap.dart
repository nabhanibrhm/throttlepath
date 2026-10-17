import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:ui' show Offset, Rect;

import 'package:flutter/foundation.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import 'carto_watermark.dart';

/// A decoded basemap tile and the world-pixel box it covers at
/// [ShareBasemap.zoom].
///
/// "World pixels" is the Web Mercator plane at a given zoom: the whole earth is
/// `256 * 2^zoom` pixels square, and tile `(x, y)` owns
/// `[x*256, y*256] .. [(x+1)*256, (y+1)*256]`. Everything on a share card's map
/// — the tiles and the route drawn over them — is placed in this one space, so
/// the line cannot drift off the roads underneath it.
@immutable
class ShareBasemapTile {
  const ShareBasemapTile(this.image, this.world);

  final ui.Image image;
  final Rect world;
}

/// The basemap resolved for one card, ready to paint synchronously.
///
/// The whole point of this type is that it holds *decoded* [ui.Image]s. A live
/// `FlutterMap` inside the card cannot work: `captureWidgetToPng` waits two
/// frames and then rasterises, and tiles do not load in two frames — the export
/// would catch a half-drawn map, differently each time. Resolving the tiles up
/// front keeps `ShareCard` a pure synchronous painter, so the PNG the rider gets
/// is exactly the preview they approved.
///
/// Owns its images: call [dispose] when the card that used it is gone.
@immutable
class ShareBasemap {
  const ShareBasemap({
    required this.zoom,
    required this.crop,
    required this.tiles,
  });

  /// Integer Web Mercator zoom the [tiles] were fetched at.
  final double zoom;

  /// The world-pixel box the card should show.
  ///
  /// This is the ride's own bounds plus a margin — *not* the shape of the box the
  /// card has to put it in. The card letterboxes this inside whatever space the
  /// layout gives the route, so the map panel is the ride's own footprint rather
  /// than a window cropped to a column's aspect ratio.
  final Rect crop;

  final List<ShareBasemapTile> tiles;

  static const _crs = Epsg3857();

  /// Where a fix lands in world-pixel space — the same space [crop] and
  /// [ShareBasemapTile.world] are in.
  Offset worldOf(double lat, double lon) =>
      _crs.latLngToOffset(LatLng(lat, lon), zoom);

  void dispose() {
    for (final tile in tiles) {
      tile.image.dispose();
    }
  }
}

/// Fetches the raw bytes of one tile, or null if it could not be had.
///
/// A seam, so the tile maths can be tested without a network or a device cache.
typedef ShareTileFetcher = Future<Uint8List?> Function(String url);

/// Resolves the basemap behind a share card's route.
///
/// Offline-first, and silently so: the cache is asked first, the network only
/// fills what the cache missed, and a ride over ground the rider has never
/// loaded simply returns null. The card then renders the way it always has —
/// transparent, route only. A share must never fail because a tile server did.
class ShareBasemapLoader {
  ShareBasemapLoader._();

  static const int tileSize = 256;

  /// How much detail to fetch, in device pixels along the crop's longer side.
  ///
  /// The widest route box any layout gives is Stacked's ~324dp, which is 972px in
  /// the 1080 export; 1024 covers it with a little to spare. Asking for the
  /// export's density rather than the preview's is the difference between a crisp
  /// card and one whose map is visibly upscaled — the canvas paints the tiles
  /// through a 3x transform.
  static const double _targetPx = 1024;

  /// Ceiling on tiles per card. Twenty-five is a 5x5 grid; the extra five absorb
  /// a crop that straddles tile boundaries on both axes.
  static const int _maxTiles = 30;

  static const int _minZoom = 2;

  /// CARTO serves past this, but a share card is looked at for a second on a
  /// phone. Beyond 18 the extra zoom buys building outlines nobody reads.
  static const int _maxZoom = 18;

  /// Breathing room around the ride, as a fraction of its longer span.
  static const double _margin = 0.12;

  /// Floor on the crop's size in world pixels at the chosen zoom.
  ///
  /// Without it a lap of a car park picks the maximum zoom, spans 60px, and is
  /// then blown up into the route box — a blur of one road. Growing the crop
  /// instead pulls the camera back and shows where the ride was.
  static const double _minCropPx = 384;

  /// Widest crop the card will draw, long side over short.
  ///
  /// A dead-straight ride has a bounding box of effectively zero width, and
  /// "crop to the ride" taken literally would render it as a 4px ribbon of map.
  /// Past 3:1 the short side grows instead.
  static const double _maxAspect = 3.0;

  static const Duration _perTileTimeout = Duration(seconds: 6);

  /// How long the whole basemap may take before the card gives up and renders
  /// without one. The rider is standing in the share sheet waiting.
  static const Duration _totalTimeout = Duration(seconds: 12);

  static const _crs = Epsg3857();

  /// Resolves the tiles covering [route], or null if there is nothing to show.
  ///
  /// [urlTemplate] is a `{s}/{z}/{x}/{y}` tile template — passed in rather than
  /// hardcoded so the one copy of the app's basemap URL stays where the maps are.
  static Future<ShareBasemap?> load({
    required List<LatLng> route,
    required String urlTemplate,
    List<String> subdomains = const ['a', 'b', 'c', 'd'],
    ShareTileFetcher? fetch,
  }) async {
    if (route.isEmpty) return null;
    final fetcher = fetch ?? cacheThenNetwork;

    // Zoom is derived, not searched: world pixels are exactly 2^zoom, so one log
    // does what a loop would.
    final atZero = _spanAt(route, 0);
    final longestAtZero =
        math.max(atZero.width, atZero.height) * (1 + 2 * _margin);
    var zoom = longestAtZero <= 0
        ? _maxZoom
        : (math.log(_targetPx / longestAtZero) / math.ln2).floor();
    zoom = zoom.clamp(_minZoom, _maxZoom);

    // Back off until the tile grid fits the budget. Only bites on a very long
    // ride, where the crop is wide enough that a whole zoom step is not missed.
    var crop = cropFor(route, zoom.toDouble());
    while (zoom > _minZoom && tileCount(crop, zoom) > _maxTiles) {
      zoom--;
      crop = cropFor(route, zoom.toDouble());
    }
    if (tileCount(crop, zoom) > _maxTiles) return null;

    final tiles = await _fetchTiles(
      crop: crop,
      zoom: zoom,
      urlTemplate: urlTemplate,
      subdomains: subdomains,
      fetch: fetcher,
    ).timeout(_totalTimeout, onTimeout: () => const []);

    // Silent fallback, by decision: an uncached area with no signal gives the
    // rider the card they had before this feature existed, not an error.
    if (tiles.isEmpty) return null;
    return ShareBasemap(zoom: zoom.toDouble(), crop: crop, tiles: tiles);
  }

  /// The route's bounding box in world pixels at [zoom].
  static Rect _spanAt(List<LatLng> route, double zoom) {
    var minX = double.infinity, maxX = double.negativeInfinity;
    var minY = double.infinity, maxY = double.negativeInfinity;
    for (final p in route) {
      final o = _crs.latLngToOffset(p, zoom);
      minX = math.min(minX, o.dx);
      maxX = math.max(maxX, o.dx);
      minY = math.min(minY, o.dy);
      maxY = math.max(maxY, o.dy);
    }
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  /// The ride's bounds, margined, floored and aspect-clamped — what the card
  /// actually shows. Visible for testing.
  @visibleForTesting
  static Rect cropFor(List<LatLng> route, double zoom) {
    final bounds = _spanAt(route, zoom);
    final pad = math.max(bounds.width, bounds.height) * _margin;
    final box = bounds.inflate(pad);

    var w = math.max(box.width, _minCropPx);
    var h = math.max(box.height, _minCropPx);
    // Grow the short side rather than trimming the long one: the long side is
    // the ride, and cropping it would drop the thing the card is of.
    if (w / h > _maxAspect) h = w / _maxAspect;
    if (h / w > _maxAspect) w = h / _maxAspect;

    final world = tileSize * math.pow(2, zoom).toDouble();
    var centre = box.center;
    // Keep the crop inside the world so the tile range never wraps. Only
    // reachable on a crop wider than the map itself, i.e. at [_minZoom].
    if (w < world) {
      centre = Offset(centre.dx.clamp(w / 2, world - w / 2), centre.dy);
    }
    if (h < world) {
      centre = Offset(centre.dx, centre.dy.clamp(h / 2, world - h / 2));
    }
    return Rect.fromCenter(center: centre, width: w, height: h);
  }

  @visibleForTesting
  static int tileCount(Rect crop, int zoom) {
    final r = tileRange(crop, zoom);
    return (r.right - r.left + 1) * (r.bottom - r.top + 1);
  }

  /// Inclusive tile index range covering [crop], clamped to the world.
  @visibleForTesting
  static ({int left, int top, int right, int bottom}) tileRange(
      Rect crop, int zoom) {
    final last = math.pow(2, zoom).toInt() - 1;
    int clamp(int v) => v.clamp(0, last);
    return (
      left: clamp((crop.left / tileSize).floor()),
      top: clamp((crop.top / tileSize).floor()),
      // `- 1` so a crop landing exactly on a tile boundary does not pull in the
      // tile beyond it, which on a 5x5 grid is ten wasted fetches.
      right: clamp(((crop.right - 1) / tileSize).floor()),
      bottom: clamp(((crop.bottom - 1) / tileSize).floor()),
    );
  }

  static Future<List<ShareBasemapTile>> _fetchTiles({
    required Rect crop,
    required int zoom,
    required String urlTemplate,
    required List<String> subdomains,
    required ShareTileFetcher fetch,
  }) async {
    final range = tileRange(crop, zoom);
    final pending = <Future<ShareBasemapTile?>>[];
    var n = 0;
    for (var y = range.top; y <= range.bottom; y++) {
      for (var x = range.left; x <= range.right; x++) {
        final url = tileUrl(urlTemplate, subdomains, x, y, zoom, n++);
        final world = Rect.fromLTWH(
          (x * tileSize).toDouble(),
          (y * tileSize).toDouble(),
          tileSize.toDouble(),
          tileSize.toDouble(),
        );
        pending.add(_oneTile(fetch, url, world));
      }
    }
    final settled = await Future.wait(pending);
    return [
      for (final tile in settled) ?tile,
    ];
  }

  static Future<ShareBasemapTile?> _oneTile(
      ShareTileFetcher fetch, String url, Rect world) async {
    try {
      final bytes = await fetch(url).timeout(_perTileTimeout);
      if (bytes == null || bytes.isEmpty) return null;
      // Defence in depth: whatever the fetcher is, a CARTO placeholder is a
      // missing tile, never a drawn one (see carto_watermark.dart).
      if (isWatermarkBytes(bytes)) return null;
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      codec.dispose();
      return ShareBasemapTile(frame.image, world);
    } catch (_) {
      // A missing or undecodable tile is a hole in the map, never a failed share.
      return null;
    }
  }

  @visibleForTesting
  static String tileUrl(String template, List<String> subdomains, int x, int y,
          int z, int index) =>
      template
          .replaceAll('{s}',
              subdomains.isEmpty ? '' : subdomains[index % subdomains.length])
          .replaceAll('{z}', '$z')
          .replaceAll('{x}', '$x')
          .replaceAll('{y}', '$y');

  /// The default fetcher: the app's own on-disk tile cache first, the network
  /// only for what it missed.
  ///
  /// Reads the very cache `TileCacheService` configured for the in-app maps, so a
  /// route the rider has already looked at on the History screen exports with a
  /// basemap while completely offline.
  ///
  /// CARTO placeholder tiles ("API KEY REQUIRED", see `carto_watermark.dart`) are
  /// never returned and never written back: a cached one is skipped as if it were
  /// a miss (the network is then tried, which for an old keyless URL just returns
  /// the placeholder again and is likewise refused), and a fetched one is
  /// dropped before it reaches the cache.
  ///
  /// [cache] is for tests; the app passes nothing and gets the shared one.
  static Future<Uint8List?> cacheThenNetwork(String url,
      {@visibleForTesting MapCachingProvider? cache}) async {
    final store = cache ?? _cache();
    if (store != null) {
      try {
        final hit = await store.getTile(url);
        if (hit != null &&
            !isCartoWatermark(hit.bytes, etag: hit.metadata.etag)) {
          return hit.bytes;
        }
      } catch (_) {
        // A corrupt cache entry is worth a refetch, not a hole in the map.
      }
    }

    final client = HttpClient()
      ..userAgent = 'id.co.opentrack.throttlepath'
      ..connectionTimeout = _perTileTimeout;
    try {
      final response = await (await client.getUrl(Uri.parse(url))).close();
      if (response.statusCode != 200) {
        await response.drain<void>();
        return null;
      }
      // The ETag settles it without reading the body; the bytes are checked as
      // well in case the header ever goes missing.
      if (isWatermarkEtag(response.headers.value(HttpHeaders.etagHeader))) {
        await response.drain<void>();
        return null;
      }
      final bytes = await consolidateHttpClientResponseBytes(response);
      if (isWatermarkBytes(bytes)) return null;
      if (store != null) unawaited(_store(store, url, response, bytes));
      return bytes;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  static MapCachingProvider? _cache() {
    try {
      // Returns the singleton TileCacheService pinned to the app's support dir
      // during startup; the arguments only apply to the call that creates it.
      final provider = BuiltInMapCachingProvider.getOrCreateInstance();
      return provider.isSupported ? provider : null;
    } catch (_) {
      return null;
    }
  }

  /// Writes a freshly fetched tile back, so the in-app map gets it too.
  static Future<void> _store(MapCachingProvider cache, String url,
      HttpClientResponse response, Uint8List bytes) async {
    try {
      final headers = <String, String>{};
      response.headers.forEach((name, values) {
        if (values.isNotEmpty) headers[name] = values.first;
      });
      await cache.putTile(
        url: url,
        metadata: CachedMapTileMetadata.fromHttpHeaders(headers),
        bytes: bytes,
      );
    } catch (_) {
      // Best effort — the tile is already in hand for this card.
    }
  }
}
