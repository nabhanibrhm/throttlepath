import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/units.dart';
import '../data/models/ride.dart';
import '../data/models/track_point.dart';
import '../ui/share_card.dart';
import 'share_basemap.dart';
import 'share_channel.dart';
import 'widget_to_image.dart';

/// Where a shared image ended up going.
enum ShareOutcome {
  /// Opened directly in Instagram Stories.
  instagramStory,

  /// Instagram not installed — routed to the system share sheet instead.
  systemChooser,
}

/// Renders a ride as a branded PNG (see [ShareCard]) and either hands it to
/// Instagram Stories or saves it straight to the device's gallery. All heavy
/// work — PNG encode + file write — happens off the UI thread; the platform
/// intent / gallery insert is dispatched via a [MethodChannel] to the Android
/// host (see MainActivity.kt).
class RideShare {
  RideShare._();

  static const _channel = ShareChannel.channel;

  /// The sticker canvas and its output density.
  ///
  /// Read from the card rather than restated: the PNG the rider gets has to be
  /// the card they previewed, and a second copy of the size here is exactly how
  /// it could stop being. Instagram receives this as `interactive_asset_uri` — a
  /// scalable sticker overlay, not a background — so a square export is placed
  /// and sized by hand on the Story rather than letterboxed into it.
  static const _canvas = ShareCard.canvasSize;
  static const _pixelRatio = 3.0; // → 1080 × 1080 PNG

  /// Instagram Story background gradient painted behind the transparent sticker.
  static const _topBackgroundColor = '#241A05';
  static const _bottomBackgroundColor = '#0A0A0A';

  static Future<Uint8List> _renderPng(
    BuildContext context,
    Ride ride,
    List<TrackPoint> points,
    SpeedUnit unit,
    ShareLayout layout,
    bool scrim,
    List<int> stintStarts,
    ShareBasemap? basemap,
  ) async {
    // The off-screen capture only waits a couple of frames, so make sure the
    // brand logo is decoded into the image cache first (otherwise it can render
    // blank on the first paint).
    await precacheImage(ShareCard.brandLogo, context);
    if (!context.mounted) {
      throw StateError('Context unmounted before render.');
    }
    return captureWidgetToPng(
      context,
      child: ShareCard(
        ride: ride,
        points: points,
        unit: unit,
        layout: layout,
        scrim: scrim,
        stintStarts: stintStarts,
        basemap: basemap,
      ),
      logicalSize: _canvas,
      pixelRatio: _pixelRatio,
    );
  }

  /// Writes to the app's private cache (not the public gallery), under a
  /// dedicated folder that FileProvider is scoped to.
  static Future<File> _writeToCache(Ride ride, Uint8List pngBytes) async {
    final shareDir = await ShareChannel.cacheFolder('share_images');
    final file = File('${shareDir.path}/ride_${ride.id}.png');
    await file.writeAsBytes(pngBytes, flush: true);
    return file;
  }

  /// Renders [ride] (+ its [points]) and shares it to Instagram (with a
  /// system-sharesheet fallback). Returns where it went.
  ///
  /// Throws if capture or the platform call fails; callers should surface a
  /// message and clear any loading state.
  static Future<ShareOutcome> shareToInstagram({
    required BuildContext context,
    required Ride ride,
    required List<TrackPoint> points,
    required SpeedUnit unit,
    required ShareLayout layout,
    required bool scrim,
    List<int> stintStarts = const [],
    ShareBasemap? basemap,
  }) async {
    final pngBytes =
        await _renderPng(
            context, ride, points, unit, layout, scrim, stintStarts, basemap);
    final file = await _writeToCache(ride, pngBytes);

    // Hand off to the Android host, which builds the content:// URI via
    // FileProvider and fires the Instagram (or fallback) intent.
    final result = await _channel.invokeMethod<String>('shareToInstagram', {
      'filePath': file.path,
      'topColor': _topBackgroundColor,
      'bottomColor': _bottomBackgroundColor,
    });

    return result == 'story'
        ? ShareOutcome.instagramStory
        : ShareOutcome.systemChooser;
  }

  /// Renders [ride] (+ its [points]) and opens the system share sheet on the PNG
  /// — WhatsApp, Telegram, mail, anything installed.
  ///
  /// Separate from [shareToInstagram] because that one is a targeted intent
  /// (ADD_TO_STORY, with an explicit package grant) that only *falls back* to the
  /// chooser; this asks for the chooser outright, so "More…" doesn't have to
  /// pretend to be a failed Instagram share.
  ///
  /// Throws if capture or the platform call fails.
  static Future<void> shareToSystem({
    required BuildContext context,
    required Ride ride,
    required List<TrackPoint> points,
    required SpeedUnit unit,
    required ShareLayout layout,
    required bool scrim,
    List<int> stintStarts = const [],
    ShareBasemap? basemap,
  }) async {
    final pngBytes =
        await _renderPng(
            context, ride, points, unit, layout, scrim, stintStarts, basemap);
    final file = await _writeToCache(ride, pngBytes);
    final name = ride.name?.trim();
    await _channel.invokeMethod('shareFile', {
      'filePath': file.path,
      'mimeType': 'image/png',
      'title': name?.isNotEmpty == true ? name! : 'ThrottlePath ride',
    });
  }

  /// Renders [ride] (+ its [points]) and saves it into the device's Photos
  /// app, in a "ThrottlePath" album. Android 10+ needs no permission for this
  /// (scoped storage); on older Android the native side reports back if the
  /// legacy storage permission is missing, so it's only requested when
  /// actually needed.
  ///
  /// Throws if capture, the platform call, or the permission request fails;
  /// callers should surface a message and clear any loading state.
  static Future<void> saveToGallery({
    required BuildContext context,
    required Ride ride,
    required List<TrackPoint> points,
    required SpeedUnit unit,
    required ShareLayout layout,
    required bool scrim,
    List<int> stintStarts = const [],
    ShareBasemap? basemap,
  }) async {
    final pngBytes =
        await _renderPng(
            context, ride, points, unit, layout, scrim, stintStarts, basemap);
    final file = await _writeToCache(ride, pngBytes);

    try {
      await _channel.invokeMethod('saveToGallery', {'filePath': file.path});
    } on PlatformException catch (e) {
      if (e.code != 'permission_denied') rethrow;
      final status = await Permission.storage.request();
      if (!status.isGranted) {
        throw StateError('Storage permission denied');
      }
      await _channel.invokeMethod('saveToGallery', {'filePath': file.path});
    }
  }
}
