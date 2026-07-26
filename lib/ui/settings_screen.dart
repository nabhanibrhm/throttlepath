import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/speed_gauge_style.dart';
import '../providers/history_providers.dart';
import '../providers/settings_providers.dart';
import '../services/geocode_backfill.dart';
import '../theme/app_theme.dart';

/// Settings tab, following the design mockup: a Display section (speed unit +
/// dark mode) over a version footer.
///
/// The dark-mode toggle is a deliberate addition to the mockup (which shows
/// both themes with no visible switch) so riders can override the theme in-app.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cx = AppColors.of(context);
    final isDark = ref.watch(themeModeProvider) == ThemeMode.dark;
    final unit = ref.watch(speedUnitProvider);
    final gaugeStyle = ref.watch(speedGaugeStyleProvider);

    return Scaffold(
      backgroundColor: cx.canvas,
      appBar: AppBar(
        backgroundColor: cx.canvas,
        foregroundColor: cx.textBright,
        elevation: 0,
        automaticallyImplyLeading: false,
        title: Text('Settings',
            style: TextStyle(
                color: cx.textBright,
                fontSize: 20,
                fontWeight: FontWeight.w800)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          _SectionLabel('Display'),
          _SettingsTile(
            icon: Icons.speed,
            title: 'Speed unit',
            trailing: Text(
              unit.speedLabel,
              style: TextStyle(color: cx.textDim, fontSize: 13),
            ),
            onTap: () => ref.read(speedUnitProvider.notifier).toggle(),
          ),
          const SizedBox(height: 12),
          _SettingsTile(
            icon: gaugeStyle == SpeedGaugeStyle.analog
                ? Icons.donut_large
                : Icons.pin_outlined,
            title: 'Live speed',
            trailing: Text(
              gaugeStyle.label,
              style: TextStyle(color: cx.textDim, fontSize: 13),
            ),
            onTap: () => ref.read(speedGaugeStyleProvider.notifier).toggle(),
          ),
          const SizedBox(height: 12),
          _SettingsTile(
            icon: isDark ? Icons.dark_mode : Icons.light_mode,
            title: 'Dark mode',
            trailing: Switch(
              value: isDark,
              activeThumbColor: cx.onAccent,
              activeTrackColor: cx.accent,
              onChanged: (_) => ref.read(themeModeProvider.notifier).toggle(),
            ),
            onTap: () => ref.read(themeModeProvider.notifier).toggle(),
          ),
          const SizedBox(height: 24),
          _SectionLabel('Data'),
          const _RelabelPlacesTile(),
          const SizedBox(height: 40),
          Center(
            child: Text('ThrottlePath v1.0.0',
                style: TextStyle(color: cx.textDim, fontSize: 12)),
          ),
        ],
      ),
    );
  }
}

/// One-time "Refresh place names" action: re-geocodes every ride's start/end to
/// the current "subdistrict, city" format (upgrading older subdistrict-only
/// labels). Shows a spinner while running and a result snackbar, then refreshes
/// History so the new names show immediately.
class _RelabelPlacesTile extends ConsumerStatefulWidget {
  const _RelabelPlacesTile();

  @override
  ConsumerState<_RelabelPlacesTile> createState() => _RelabelPlacesTileState();
}

class _RelabelPlacesTileState extends ConsumerState<_RelabelPlacesTile> {
  bool _busy = false;
  int _done = 0;
  int _total = 0;

  Future<void> _run() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _done = 0;
      _total = 0;
    });
    var updated = 0;
    try {
      updated = await GeocodeBackfill.instance.relabelAll(
        onProgress: (done, total) {
          if (!mounted) return;
          setState(() {
            _done = done;
            _total = total;
          });
        },
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    // Refresh anything that displays place names.
    ref.invalidate(rideHistoryProvider);
    ref.invalidate(finishedTripsProvider);
    ref.invalidate(openTripsProvider);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(updated == 0
            ? 'Place names are already up to date.'
            : 'Updated place names on $updated ride${updated == 1 ? '' : 's'}.'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    return _SettingsTile(
      icon: Icons.place_outlined,
      title: 'Refresh place names',
      trailing: _busy
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_total > 0)
                  Text('$_done/$_total',
                      style: TextStyle(color: cx.textDim, fontSize: 13)),
                const SizedBox(width: 10),
                SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: cx.accentInk),
                ),
              ],
            )
          : Icon(Icons.refresh, color: cx.textDim, size: 20),
      onTap: _busy ? () {} : _run,
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 10),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          color: cx.textDim,
          fontSize: 12,
          letterSpacing: 1.2,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  const _SettingsTile({
    required this.icon,
    required this.title,
    this.trailing,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final Widget? trailing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    return Material(
      color: cx.surface,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: cx.canvas,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: cx.accentInk, size: 19),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(title,
                    style: TextStyle(
                        color: cx.textBright,
                        fontSize: 15,
                        fontWeight: FontWeight.w700)),
              ),
              ?trailing,
            ],
          ),
        ),
      ),
    );
  }
}
