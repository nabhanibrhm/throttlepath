import 'dart:convert';
import 'dart:typed_data';

/// Recognises the "API KEY REQUIRED" placeholder tile CARTO serves instead of a
/// map when a request carries no valid key.
///
/// Why this exists: since Sept 2026 CARTO answers a keyless (or bad-key, or
/// out-of-quota) tile request with `200 OK` and a PNG that has
/// `carto.com/basemaps/apikey` drawn diagonally over a flat background. To an
/// HTTP client that is a perfectly successful download, so without this check
/// the watermark gets cached and, worse, baked into an exported share PNG.
///
/// What was measured (curl, 2026-10-15):
///
/// * **Headers differ.** A placeholder carries `ETag: "wm-da89c20e77c1-dark"`
///   (or `...-light`) and `Cache-Control: ... immutable`; a real tile carries
///   `ETag: "martin-<date>-NN"` and no `immutable`. A deliberately bogus key
///   gets the same `wm-` placeholder as no key at all.
/// * **Bodies are constant.** The placeholder is byte-identical across every
///   z/x/y tried (z0..z19, both `a` and `b` hosts, plus `@2x` and `nolabels`
///   variants): dark is 2513 bytes, md5 df9307c738f2c6dbc0f8d31837019f98; light
///   (also what the `voyager` style returns) is 2049 bytes, md5
///   502fc5f6793fad87dcf8ba3fa646c38f. One fixed image per light/dark theme.
/// * **Size is not a usable test.** A real open-ocean tile is a 103-byte PNG,
///   far smaller than either placeholder, so any "small means placeholder"
///   threshold would one day eat a real tile.
///
/// So detection is two independent checks, either of which is enough:
///
/// 1. [isWatermarkEtag] — the `wm-` ETag. Cheapest and survives CARTO redrawing
///    the placeholder, but it is only available when we have headers: a live
///    response, or a cached tile's stored metadata.
/// 2. [isWatermarkBytes] — exact byte equality with the two known placeholders
///    (length first, so a real tile is rejected after a single int compare).
///    This is the backstop for when headers are missing. Exact equality rather
///    than a size or hash heuristic means a real tile can never be misclassified:
///    it would have to be the placeholder, byte for byte.
///
/// If CARTO ever redraws the placeholder *and* drops the `wm-` ETag, this stops
/// matching and the new placeholder would pass as a map. Nothing here can detect
/// an image it has never seen; refresh the fixtures in `test/fixtures/` if the
/// ETag prefix ever changes.
bool isCartoWatermark(Uint8List? bytes, {String? etag}) =>
    isWatermarkEtag(etag) || (bytes != null && isWatermarkBytes(bytes));

/// True for the placeholder's `ETag`, quoted or not, weak or strong.
bool isWatermarkEtag(String? etag) {
  if (etag == null) return false;
  var e = etag.trim();
  if (e.startsWith('W/')) e = e.substring(2);
  if (e.startsWith('"')) e = e.substring(1);
  return e.startsWith('wm-');
}

/// True if [bytes] is exactly one of CARTO's known placeholder tiles.
bool isWatermarkBytes(Uint8List bytes) {
  for (final known in _placeholders) {
    if (bytes.length != known.length) continue;
    var same = true;
    for (var i = 0; i < bytes.length; i++) {
      if (bytes[i] != known[i]) {
        same = false;
        break;
      }
    }
    if (same) return true;
  }
  return false;
}

final List<Uint8List> _placeholders = [
  base64Decode(_darkB64),
  base64Decode(_lightB64),
];

// Regenerate with `base64 -w 70 test/fixtures/carto_watermark_<theme>.png`.
const _darkB64 =
    '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';

const _lightB64 =
    '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'
    'CC';
