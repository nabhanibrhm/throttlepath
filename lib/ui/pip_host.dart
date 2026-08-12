import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/pip_providers.dart';
import '../services/pip_service.dart';
import 'pip_card.dart';

/// Wraps the entire app to (a) tell Android when a ride is live enough to be worth
/// shrinking into a Picture-in-Picture window, and (b) swap that window's contents
/// in when the system grants it.
///
/// Mounted from `MaterialApp.builder` rather than around `home`, which is
/// load-bearing: the splash reaches `HomeShell` with `pushReplacement`, so anything
/// wrapping `home` is torn out of the tree the moment bootstrap finishes. `builder`
/// wraps the [Navigator] itself, so this survives every route change — and swapping
/// [child] for the card hides the whole navigation stack without disturbing it, so
/// leaving PiP returns to exactly the screen the rider was on.
class PipHost extends ConsumerWidget {
  const PipHost({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Arming is a `listen`, not a `watch`: it must not rebuild this widget, which
    // sits above the entire app. `pipShouldArmProvider` is a plain Provider, so it
    // recomputes on every one-second telemetry tick but only notifies here on an
    // actual transition — one channel call per ride start and stop, not per second.
    //
    // Transitions only, with no initial push, and that is sufficient rather than a
    // gap: `PipController` starts disarmed and this provider starts false, so the
    // two already agree on the first frame. Even the awkward case is covered — an
    // app relaunched while the service is still recording builds this widget before
    // `TrackingController` adopts the running ride, so `false → true` is a real
    // transition and does arrive here.
    ref.listen<bool>(
      pipShouldArmProvider,
      (_, armed) => PipService.instance.setArmed(armed),
    );

    final inPip = ref.watch(pipModeProvider);

    // `child` is passed through untouched, so when PiP ends the Navigator element
    // is reused rather than rebuilt from scratch.
    return inPip ? const PipCardHost() : child;
  }
}
