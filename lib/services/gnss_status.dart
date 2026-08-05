/// What the GNSS receiver is doing — the constellation behind a fix, and how long
/// the fix took to arrive.
library;

import 'package:flutter/services.dart';

/// One report from the platform receiver.
///
/// Two shapes travel the same channel because they come from the same native
/// callback object, and registering it twice would mean two GNSS subscriptions
/// for one screen.
sealed class GnssEvent {
  const GnssEvent();
}

/// One constellation snapshot, as reported by the platform receiver.
class GnssSnapshot extends GnssEvent {
  const GnssSnapshot({required this.visible, required this.usedInFix});

  /// Satellites the receiver can hear at all.
  final int visible;

  /// Satellites actually contributing to the current fix. Four is the floor for
  /// a 3D position, so this — not [visible] — is the number that says whether a
  /// lock is close.
  final int usedInFix;

  static const empty = GnssSnapshot(visible: 0, usedInFix: 0);

  /// Whether the receiver has heard anything yet. False both before the first
  /// callback and after the chip powers down, which read the same to a rider:
  /// nothing up there is talking to us.
  bool get hasSignal => visible > 0;

  /// `4 of 11 satellites`, or null when there is no constellation report at all
  /// — which is not the same as a report of zero, and must not be rendered as
  /// "0 of 0". Shared so the acquiring readout and the blackout notice cannot
  /// word the same fact differently.
  String? get satellitePhrase =>
      hasSignal ? '$usedInFix of $visible satellites' : null;

  @override
  bool operator ==(Object other) =>
      other is GnssSnapshot &&
      other.visible == visible &&
      other.usedInFix == usedInFix;

  @override
  int get hashCode => Object.hash(visible, usedInFix);

  @override
  String toString() => 'GnssSnapshot($usedInFix/$visible)';
}

/// The receiver's own time-to-first-fix for this acquisition.
///
/// Reported once per cold start, by the chip, in the units the chip measured —
/// so it excludes everything on our side of the boundary. Fires only when the
/// GNSS engine actually acquires from nothing, which is exactly the sample worth
/// keeping: a warm receiver that already had a fix reports nothing here rather
/// than contributing a flattering near-zero.
class GnssFirstFix extends GnssEvent {
  const GnssFirstFix(this.ttffMillis);

  final int ttffMillis;

  @override
  bool operator ==(Object other) =>
      other is GnssFirstFix && other.ttffMillis == ttffMillis;

  @override
  int get hashCode => ttffMillis.hashCode;

  @override
  String toString() => 'GnssFirstFix(${ttffMillis}ms)';
}

/// A stream of receiver reports.
///
/// Mirrors [LocationSource]'s shape deliberately: a thin seam so widgets and
/// tests never touch the platform channel directly, and so a device that cannot
/// answer is a silent stream rather than a special case at every call site.
abstract class GnssStatusSource {
  Stream<GnssEvent> events();

  /// The Android `LocationManager.registerGnssStatusCallback` bridge. Silent on
  /// any platform that cannot answer — see [_PlatformGnssStatusSource].
  factory GnssStatusSource.platform() => const _PlatformGnssStatusSource();
}

class _PlatformGnssStatusSource implements GnssStatusSource {
  const _PlatformGnssStatusSource();

  static const _channel = EventChannel('id.co.opentrack.throttlepath/gnss');

  @override
  Stream<GnssEvent> events() => _channel.receiveBroadcastStream().map(_decode)
      // No GNSS chip, an older platform, a permission revoked mid-stream:
      // all of them become "this stream never says anything", which is the
      // fallback the readout is written against. Surfacing an error would
      // put something on the acquiring screen the rider cannot act on.
      .handleError((Object _) {});

  /// A `ttffMillis` key marks the first-fix report; anything else is a
  /// constellation snapshot.
  static GnssEvent _decode(Object? event) {
    final map = event as Map<Object?, Object?>;
    final ttff = (map['ttffMillis'] as num?)?.toInt();
    if (ttff != null) return GnssFirstFix(ttff);
    return GnssSnapshot(
      visible: (map['visible'] as num?)?.toInt() ?? 0,
      usedInFix: (map['usedInFix'] as num?)?.toInt() ?? 0,
    );
  }
}
