/// The progress line under "ACQUIRING GPS…".
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/ttff.dart';
import '../providers/settings_providers.dart';
import '../providers/tracking_providers.dart';
import '../theme/app_theme.dart';

/// Says what the receiver is doing while the rider waits for a lock: how many
/// satellites it can hear, how many are contributing, how long it has been
/// trying, and how long that usually takes on this phone.
///
/// F9's complaint was that the acquiring pill is indefinite — nothing on the
/// screen distinguishes "eight seconds in, four satellites, nearly there" from
/// "the app has hung". Every part of this answers that, and they answer it
/// independently: the counter keeps ticking on a device that reports no
/// constellation at all, which is the fallback [GnssStatusSource.platform]
/// leaves us with below API 24 or without a GNSS chip. The typical figure is what
/// turns the counter from a number into a comparison — "12s" means nothing until
/// you know a lock here usually costs 18.
class AcquiringProgress extends ConsumerStatefulWidget {
  const AcquiringProgress({super.key});

  @override
  ConsumerState<AcquiringProgress> createState() => _AcquiringProgressState();
}

class _AcquiringProgressState extends ConsumerState<AcquiringProgress> {
  /// Seconds since this line appeared. The widget mounts exactly when the
  /// acquiring phase begins and is disposed when it ends, so its own lifetime
  /// *is* the elapsed time — no clock has to be threaded through the state.
  int _seconds = 0;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(
      const Duration(seconds: 1),
      (_) => setState(() => _seconds++),
    );
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    // The chip reports its own time-to-first-fix exactly once per acquisition,
    // and this widget is mounted for precisely that window — so filing the
    // sample belongs here rather than anywhere with a longer life.
    ref.listen(gnssFirstFixProvider, (_, next) {
      final fix = next.valueOrNull;
      if (fix != null) {
        ref.read(ttffSamplesProvider.notifier).record(fix.ttffMillis);
      }
    });

    final gnss = ref.watch(gnssStatusProvider).valueOrNull;
    // "0 of 11 satellites" is real progress and worth showing; "0 of 0" is not
    // a constellation report, it's the absence of one.
    final satellites = gnss?.satellitePhrase ?? 'Searching for satellites';
    final typical = typicalTtffLabel(ref.watch(ttffSamplesProvider));

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$satellites · ${_seconds}s',
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: cx.textDim,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              // The counter would otherwise re-flow the whole line every second
              // as the digits change width.
              fontFeatures: kTabularFigures,
            ),
          ),
          // Reserved whether or not there is a figure to show. The samples load
          // a frame or two after this mounts, and on the ride that first fills
          // the window the line appears mid-wait — neither should shove the
          // CANCEL button down while the rider is looking at it.
          SizedBox(
            height: _typicalLineHeight,
            // Padding rather than an Align: Align fills the width it is offered,
            // which would make the whole readout jump to the full width of the
            // sheet the moment this line appears.
            child: typical == null
                ? null
                : Padding(
                    padding: const EdgeInsets.only(top: 5),
                    child: Text(
                      typical,
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: cx.textTertiary,
                        fontSize: kMinFontSize,
                        fontWeight: FontWeight.w600,
                        fontFeatures: kTabularFigures,
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  /// Height held for the "usually about Ns" line — the text plus the gap above
  /// it. Fixed, so the readout occupies the same box before and after this phone
  /// has enough history to fill it.
  static const double _typicalLineHeight = 20;
}
