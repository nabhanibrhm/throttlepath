import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/record_view.dart';
import '../core/speed_gauge_style.dart';
import '../core/units.dart';
import '../providers/history_providers.dart';
import '../providers/settings_providers.dart';
import '../services/geocode_backfill.dart';
import '../services/rides_csv_export.dart';
import '../theme/app_theme.dart';

/// Settings, grouped by what a row *is about* rather than by when it was added
/// (F32): **Units · Display · Ride screen · Recording · Data · About**.
///
/// Speed unit used to sit under "Display" next to the theme switch, which put a
/// measurement system and a colour scheme in the same bucket. Units get their own
/// heading because they change every number in the app; Display only changes how
/// it looks.
///
/// Every row is at least [_kRowMinHeight] tall — the audit found several under
/// the 48dp target, which on a phone held in gloves is the difference between a
/// setting and a coin toss.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cx = AppColors.of(context);
    final themeMode = ref.watch(themeModeProvider);
    final unit = ref.watch(speedUnitProvider);
    final view = ref.watch(recordViewProvider);
    final gaugeStyle = ref.watch(speedGaugeStyleProvider);
    final countdown = ref.watch(countdownEnabledProvider);
    final keepScreenOn = ref.watch(keepScreenOnProvider);

    return Scaffold(
      backgroundColor: cx.canvas,
      appBar: AppBar(
        backgroundColor: cx.canvas,
        foregroundColor: cx.textBright,
        elevation: 0,
        automaticallyImplyLeading: false,
        title: Text(
          'Settings',
          style: TextStyle(
            color: cx.textBright,
            fontSize: 20,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          const _SectionLabel('Units'),
          _SettingsTile(
            icon: Icons.straighten,
            title: 'Speed and distance',
            subtitle: unit == SpeedUnit.kmh
                ? 'Kilometres per hour and kilometres.'
                : 'Miles per hour and miles.',
            trailing: _ValueText(unit.speedLabel),
            onTap: () => ref.read(speedUnitProvider.notifier).toggle(),
            semanticValue: unit.speedLabel,
          ),
          const SizedBox(height: 24),

          const _SectionLabel('Display'),
          _ThemeTile(mode: themeMode),
          const SizedBox(height: 24),

          // A mirror of the Record screen's own switcher, not the only way in
          // (F1). Both surfaces read their labels off the same enums, so the
          // wording here can never drift from the chips there.
          const _SectionLabel('Ride screen'),
          _SettingsTile(
            icon: switch (view) {
              RecordView.map => Icons.map_outlined,
              RecordView.chart => Icons.show_chart,
              RecordView.none => Icons.visibility_off_outlined,
            },
            title: 'Backdrop',
            trailing: _ValueText(view.label),
            onTap: () => ref.read(recordViewProvider.notifier).cycle(),
            semanticValue: view.label,
          ),
          const SizedBox(height: 12),
          _SettingsTile(
            icon: gaugeStyle == SpeedGaugeStyle.analog
                ? Icons.donut_large
                : Icons.pin_outlined,
            title: 'Live speed',
            trailing: _ValueText(gaugeStyle.label),
            onTap: () => ref.read(speedGaugeStyleProvider.notifier).toggle(),
            semanticValue: gaugeStyle.label,
          ),
          const SizedBox(height: 24),

          const _SectionLabel('Recording'),
          _SettingsTile(
            icon: Icons.timer_3_outlined,
            title: 'Start countdown',
            subtitle: countdown
                ? '3… 2… 1… before the clock starts. Tap it to skip.'
                : 'Recording starts as soon as GPS locks on.',
            trailing: _Toggle(
              value: countdown,
              onChanged: (_) =>
                  ref.read(countdownEnabledProvider.notifier).toggle(),
            ),
            onTap: () => ref.read(countdownEnabledProvider.notifier).toggle(),
            semanticToggled: countdown,
          ),
          const SizedBox(height: 12),
          _SettingsTile(
            icon: Icons.brightness_high_outlined,
            title: 'Keep screen on',
            subtitle: 'While a ride is recording. Uses more battery — '
                'recording itself works with the screen off.',
            trailing: _Toggle(
              value: keepScreenOn,
              onChanged: (_) =>
                  ref.read(keepScreenOnProvider.notifier).toggle(),
            ),
            onTap: () => ref.read(keepScreenOnProvider.notifier).toggle(),
            semanticToggled: keepScreenOn,
          ),
          const SizedBox(height: 24),

          const _SectionLabel('Data'),
          const _ExportRidesTile(),
          const SizedBox(height: 12),
          const _RelabelPlacesTile(),
          const SizedBox(height: 24),

          const _SectionLabel('About'),
          _SettingsTile(
            icon: Icons.motorcycle,
            title: 'ThrottlePath',
            subtitle: 'Version 1.0.0 · rides are stored on this phone only.',
            trailing: const SizedBox.shrink(),
            onTap: () {},
          ),
        ],
      ),
    );
  }
}

/// Theme as a three-way choice (System / Light / Dark), not a switch.
///
/// The old row was "Dark mode" with a `Switch`, and `loadThemeMode` collapsed
/// `ThemeMode.system` into dark on read — so following the phone was
/// unreachable *and* unstorable. A segmented control shows all three states at
/// once, which is also what makes "System" discoverable at all.
class _ThemeTile extends ConsumerWidget {
  const _ThemeTile({required this.mode});

  final ThemeMode mode;

  static const _modes = [ThemeMode.system, ThemeMode.light, ThemeMode.dark];

  IconData _icon(ThemeMode m) => switch (m) {
        ThemeMode.system => Icons.brightness_auto_outlined,
        ThemeMode.light => Icons.light_mode_outlined,
        ThemeMode.dark => Icons.dark_mode_outlined,
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cx = AppColors.of(context);
    return Container(
      decoration: BoxDecoration(
        color: cx.surface,
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _TileIcon(icon: _icon(mode)),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Theme',
                      style: TextStyle(
                        color: cx.textBright,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text(
                        mode == ThemeMode.system
                            ? 'Follows your phone’s light/dark setting.'
                            : 'Always ${themeModeLabel(mode).toLowerCase()}, '
                                'whatever the phone is set to.',
                        style: TextStyle(
                          color: cx.textTertiary,
                          fontSize: kMinFontSize,
                          height: 1.35,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              for (final m in _modes) ...[
                Expanded(
                  child: _ThemeSegment(
                    label: themeModeLabel(m),
                    selected: m == mode,
                    onTap: () =>
                        ref.read(themeModeProvider.notifier).setMode(m),
                  ),
                ),
                if (m != _modes.last) const SizedBox(width: 8),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _ThemeSegment extends StatelessWidget {
  const _ThemeSegment({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    return Semantics(
      button: true,
      selected: selected,
      label: '$label theme',
      child: Material(
        color: selected ? cx.accent : cx.canvas,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: selected ? cx.accent : cx.border),
            ),
            child: ExcludeSemantics(
              child: Text(
                label,
                style: TextStyle(
                  color: selected ? cx.onAccent : cx.textDim,
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "Export all rides" — the whole history as one CSV (F32's Data group).
class _ExportRidesTile extends ConsumerStatefulWidget {
  const _ExportRidesTile();

  @override
  ConsumerState<_ExportRidesTile> createState() => _ExportRidesTileState();
}

class _ExportRidesTileState extends ConsumerState<_ExportRidesTile> {
  bool _busy = false;

  Future<void> _run() async {
    if (_busy) return;
    setState(() => _busy = true);
    String message;
    try {
      final count = await RidesCsvExport.shareAll();
      message = 'Exported $count ride${count == 1 ? '' : 's'}.';
    } on StateError catch (e) {
      message = e.message;
    } catch (e) {
      message = 'Could not export rides: $e';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    return _SettingsTile(
      icon: Icons.file_download_outlined,
      title: 'Export all rides',
      subtitle: 'One CSV of every ride’s stats, for a spreadsheet or a backup. '
          'Full GPS tracks export per ride, from the ride itself.',
      trailing: _busy
          ? SizedBox(
              width: 18,
              height: 18,
              child:
                  CircularProgressIndicator(strokeWidth: 2, color: cx.accentInk),
            )
          : Icon(Icons.ios_share, color: cx.textDim, size: 20),
      onTap: _busy ? () {} : _run,
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
      subtitle: 'Re-looks-up the start and end of every ride. Needs a '
          'connection.',
      trailing: _busy
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_total > 0)
                  Text('$_done/$_total',
                      style: TextStyle(
                        color: cx.textDim,
                        fontSize: 13,
                        fontFeatures: kTabularFigures,
                      )),
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
      child: Semantics(
        header: true,
        child: Text(
          text.toUpperCase(),
          style: TextStyle(
            color: cx.textDim,
            fontSize: kMinFontSize,
            letterSpacing: 1.2,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

/// The value shown at the right of a tap-to-cycle row.
class _ValueText extends StatelessWidget {
  const _ValueText(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    return ExcludeSemantics(
      child: Text(text, style: TextStyle(color: cx.textDim, fontSize: 13)),
    );
  }
}

/// A switch whose own semantics are suppressed — the surrounding tile already
/// announces the setting as toggleable, and both being focusable makes a screen
/// reader read every row twice.
class _Toggle extends StatelessWidget {
  const _Toggle({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    return ExcludeSemantics(
      child: Switch(
        value: value,
        activeThumbColor: cx.onAccent,
        activeTrackColor: cx.accent,
        onChanged: onChanged,
      ),
    );
  }
}

class _TileIcon extends StatelessWidget {
  const _TileIcon({required this.icon});
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    return Container(
      width: 38,
      height: 38,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: cx.canvas,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(icon, color: cx.accentInk, size: 19),
    );
  }
}

/// Minimum height for a settings row.
const double _kRowMinHeight = 48;

class _SettingsTile extends StatelessWidget {
  const _SettingsTile({
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    required this.onTap,
    this.semanticValue,
    this.semanticToggled,
  });

  final IconData icon;
  final String title;

  /// One line of consequence, for settings whose title doesn't say what turning
  /// them on actually costs or does.
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback onTap;

  /// Spoken as the row's current value ("km/h", "Chart") — the trailing widget
  /// that shows it is excluded from semantics so it isn't read twice.
  final String? semanticValue;

  /// Set for rows that are on/off, so a screen reader announces the state and
  /// the row reads as a switch rather than a button.
  final bool? semanticToggled;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    return Semantics(
      button: semanticToggled == null,
      toggled: semanticToggled,
      label: title,
      value: semanticValue,
      hint: subtitle,
      child: Material(
        color: cx.surface,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            constraints: const BoxConstraints(minHeight: _kRowMinHeight),
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                ExcludeSemantics(child: _TileIcon(icon: icon)),
                const SizedBox(width: 14),
                Expanded(
                  child: ExcludeSemantics(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title,
                          style: TextStyle(
                            color: cx.textBright,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (subtitle != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 3, right: 8),
                            child: Text(
                              subtitle!,
                              style: TextStyle(
                                color: cx.textTertiary,
                                fontSize: kMinFontSize,
                                height: 1.35,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                ?trailing,
              ],
            ),
          ),
        ),
      ),
    );
  }
}
