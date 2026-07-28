import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/history_providers.dart';
import '../providers/home_providers.dart';
import '../providers/stats_providers.dart';
import '../theme/app_theme.dart';
import 'history_screen.dart';
import 'settings_screen.dart';
import 'tracking_map_screen.dart';

/// Root of the app after the splash: a three-tab shell (Record / History /
/// Settings) with a persistent bottom nav, mirroring the design prototype.
///
/// The tabs live in an [IndexedStack] so each keeps its state when the rider
/// switches away and back — critically, the Record tab keeps the live map and
/// an in-progress ride alive while the rider peeks at History or Settings.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  static const int _historyTab = 1;

  static const _tabs = <_TabSpec>[
    _TabSpec(icon: Icons.radio_button_checked, label: 'Record'),
    _TabSpec(icon: Icons.history, label: 'History'),
    _TabSpec(icon: Icons.tune, label: 'Settings'),
  ];

  /// Switches tabs. Entering History forces a refetch of the ride list and open
  /// trips: the tabs live in an [IndexedStack], so [HistoryScreen] never
  /// unmounts and its `autoDispose` providers would otherwise keep serving the
  /// snapshot they read at launch — never showing rides/trips saved since (the
  /// original save bug).
  void _onSelectTab(int i) {
    if (i == _historyTab) {
      ref.invalidate(rideHistoryProvider);
      ref.invalidate(openTripsProvider);
      // Also the finished trips: a trip just closed from the summary screen
      // moves out of `openTripsProvider` into this one, and without a refetch its
      // legs (which carry a tripId, so they're excluded from the standalone list)
      // would vanish from History entirely.
      ref.invalidate(finishedTripsProvider);
      // This week's totals move with every save, so the week strip has to refetch
      // for the same reason the list does.
      ref.invalidate(weekStatsProvider);
      // Re-run the best-effort place-name backfill for rides saved offline, and
      // derive route keys/shapes for any ride still missing them.
      ref.invalidate(geocodeBackfillProvider);
      ref.invalidate(routeBackfillProvider);
    }
    ref.read(homeTabProvider.notifier).state = i;
  }

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    final index = ref.watch(homeTabProvider);
    return Scaffold(
      backgroundColor: cx.canvas,
      body: IndexedStack(
        index: index,
        children: const [
          TrackingMapScreen(),
          HistoryScreen(),
          SettingsScreen(),
        ],
      ),
      bottomNavigationBar: _BottomNav(
        tabs: _tabs,
        index: index,
        onSelect: _onSelectTab,
      ),
    );
  }
}

class _TabSpec {
  const _TabSpec({required this.icon, required this.label});
  final IconData icon;
  final String label;
}

/// Prototype bottom nav: a 68px bar with a hairline top border, amber for the
/// active tab and dim grey for the rest.
class _BottomNav extends StatelessWidget {
  const _BottomNav({
    required this.tabs,
    required this.index,
    required this.onSelect,
  });

  final List<_TabSpec> tabs;
  final int index;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    return Container(
      decoration: BoxDecoration(
        color: cx.surface,
        border: Border(top: BorderSide(color: cx.border)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 68,
          child: Row(
            children: [
              for (var i = 0; i < tabs.length; i++)
                Expanded(
                  child: _NavButton(
                    spec: tabs[i],
                    active: i == index,
                    onTap: () => onSelect(i),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavButton extends StatelessWidget {
  const _NavButton({
    required this.spec,
    required this.active,
    required this.onTap,
  });

  final _TabSpec spec;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    final color = active ? cx.accentInk : cx.textDim;
    return InkWell(
      onTap: onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(spec.icon, color: color, size: 22),
          const SizedBox(height: 5),
          Text(
            spec.label,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: active ? FontWeight.w700 : FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
