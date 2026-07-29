import 'package:flutter/material.dart';

/// Speaks the live speed to a screen reader, and no more often than every
/// [announceEvery].
///
/// The speed readout updates about once a second. Marked as a plain live region
/// that is exactly what TalkBack would say — "forty-two kilometres per hour"
/// once a second, forever, over the top of everything else the rider is trying
/// to hear. Throttling is what makes the live region usable rather than an
/// interruption; five seconds is slow enough to talk over and often enough to be
/// current.
///
/// The visual child is excluded from semantics so the number is announced once,
/// as a sentence, rather than twice — once as a bare "42" and once as the
/// spoken form.
class LiveSpeedAnnouncer extends StatefulWidget {
  const LiveSpeedAnnouncer({
    super.key,
    required this.speed,
    required this.unitLabel,
    required this.active,
    required this.child,
    this.announceEvery = const Duration(seconds: 5),
  });

  /// Speed in the rider's display unit.
  final double speed;

  /// "km/h" or "mph".
  final String unitLabel;

  /// False when there is no live speed to speak of (idle, acquiring, paused) —
  /// the region goes quiet rather than announcing a frozen number as if it were
  /// current.
  final bool active;

  final Duration announceEvery;
  final Widget child;

  /// The spoken form. "42 km/h" is read as "forty-two kay em slash aitch"; the
  /// words are what a screen reader can actually pronounce.
  static String spoken(double speed, String unitLabel) {
    final unit = unitLabel == 'mph' ? 'miles per hour' : 'kilometres per hour';
    return '${speed.round()} $unit';
  }

  @override
  State<LiveSpeedAnnouncer> createState() => _LiveSpeedAnnouncerState();
}

class _LiveSpeedAnnouncerState extends State<LiveSpeedAnnouncer> {
  late double _announced = widget.speed;

  /// When [_announced] was last refreshed. Seeded at mount, because the first
  /// value *is* an announcement — leaving it null would let the very next GPS
  /// tick through and make the throttle start one window late.
  late DateTime _announcedAt = DateTime.now();

  @override
  void didUpdateWidget(covariant LiveSpeedAnnouncer old) {
    super.didUpdateWidget(old);
    // Driven off rebuilds rather than a timer: the readout already rebuilds on
    // every GPS tick, so a timer would only add a second source of truth for
    // "what has been said". If the ticks stop, the last announced value is the
    // right thing to leave standing.
    final now = DateTime.now();
    if (now.difference(_announcedAt) < widget.announceEvery) return;
    _announcedAt = now;
    if (_announced != widget.speed) {
      setState(() => _announced = widget.speed);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active) {
      return Semantics(
        label: 'Speed',
        value: 'not recording',
        child: ExcludeSemantics(child: widget.child),
      );
    }
    return Semantics(
      liveRegion: true,
      label: 'Current speed',
      value: LiveSpeedAnnouncer.spoken(_announced, widget.unitLabel),
      child: ExcludeSemantics(child: widget.child),
    );
  }
}
