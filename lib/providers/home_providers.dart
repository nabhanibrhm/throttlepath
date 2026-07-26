import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Selected bottom-nav tab index for [HomeShell]: 0 = Record, 1 = History,
/// 2 = Settings.
///
/// Lifted out of `HomeShell`'s local state into a provider so cross-tab flows
/// can drive navigation — notably "Continue trip", which is triggered from the
/// History tab but needs to bring the rider back to the Record tab.
final homeTabProvider = StateProvider<int>((ref) => 0);

/// Ids of open trips whose Record-screen proximity nudge the rider has dismissed
/// this session, so it isn't shown again until the app restarts.
final dismissedTripNudgesProvider = StateProvider<Set<int>>((ref) => <int>{});
