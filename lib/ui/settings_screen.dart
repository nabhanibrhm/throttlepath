import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/history_providers.dart';
import '../providers/pip_providers.dart';
import '../providers/settings_providers.dart';
import '../services/geocode_backfill.dart';
import '../services/rides_csv_export.dart';
import '../theme/app_theme.dart';
import 'hairline_row.dart';
import 'theme_picker_sheet.dart';

/// Settings, grouped by what a row *is about* rather than by when it was added
/// (F32): **Units · Display · Ride screen · Recording · Data · About**.
///
/// Speed unit used to sit under "Display" next to the theme switch, which put a
/// measurement system and a colour scheme in the same bucket. Units get their own
/// heading because they change every number in the app; Display only changes how
/// it looks.
///
/// The minimal pass took two things away from every row: the 36dp amber icon tile
/// (G5) and the card fill (G1). The tiles were decoration standing in for
/// meaning — "Backdrop" is not clearer with a chart glyph beside it, and eight
/// amber squares down the left made the accent worthless. Rows are hairline-
/// separated now, and the amber that remains is each row's *value*, which is the
/// one thing a rider scans a settings list for.
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
    final pipEnabled = ref.watch(pipEnabledProvider);

    return Scaffold(
      backgroundColor: cx.canvas,
      appBar: AppBar(
        backgroundColor: cx.canvas,
        foregroundColor: cx.textBright,
        elevation: 0,
        automaticallyImplyLeading: false,
        title: Text('Settings', style: Theme.of(context).textTheme.titleLarge),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          const SectionLabel(label: 'Units', rule: false),
          _SettingsTile(
            title: 'Speed and distance',
            // No subtitle (spec 8.3): "Kilometres per hour and kilometres"
            // restated the "km/h" already sitting at the end of the row.
            trailing: _ValueText(unit.speedLabel),
            onTap: () => ref.read(speedUnitProvider.notifier).toggle(),
            semanticValue: unit.speedLabel,
          ),

          const SectionLabel(label: 'Display', rule: false),
          _SettingsTile(
            title: 'Theme',
            subtitle: themeMode == ThemeMode.system
                ? 'Follows your phone’s light/dark setting.'
                : 'Always ${themeModeLabel(themeMode).toLowerCase()}, '
                    'whatever the phone is set to.',
            trailing: _ValueText(themeModeLabel(themeMode)),
            onTap: () => showThemePickerSheet(context),
            semanticValue: themeModeLabel(themeMode),
          ),

          // A mirror of the Record screen's own switcher, not the only way in
          // (F1). Both surfaces read their labels off the same enums, so the
          // wording here can never drift from the controls there.
          const SectionLabel(label: 'Ride screen', rule: false),
          _SettingsTile(
            title: 'Backdrop',
            trailing: _ValueText(view.label),
            onTap: () => ref.read(recordViewProvider.notifier).cycle(),
            semanticValue: view.label,
          ),
          _SettingsTile(
            title: 'Live speed',
            trailing: _ValueText(gaugeStyle.label),
            onTap: () => ref.read(speedGaugeStyleProvider.notifier).toggle(),
            semanticValue: gaugeStyle.label,
          ),

          const SectionLabel(label: 'Recording', rule: false),
          _SettingsTile(
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
          _SettingsTile(
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
          // Absent entirely below API 26, or on a device without the PiP feature —
          // not shown disabled. A greyed row invites the rider to work out why,
          // and the answer ("your Android is too old") is not something they can
          // act on. `valueOrNull` reads false while the check is in flight, so the
          // row appears a frame late rather than flickering out.
          if (ref.watch(pipSupportedProvider).valueOrNull ?? false)
            _SettingsTile(
              title: 'Floating window',
              subtitle: pipEnabled
                  ? 'Leaving the app mid-ride shrinks it to a small window with '
                      'live speed, distance and time. Tap it to come back.'
                  : 'Leaving the app mid-ride shows nothing. Recording carries on '
                      'either way.',
              trailing: _Toggle(
                value: pipEnabled,
                onChanged: (_) => ref.read(pipEnabledProvider.notifier).toggle(),
              ),
              onTap: () => ref.read(pipEnabledProvider.notifier).toggle(),
              semanticToggled: pipEnabled,
            ),

          const SectionLabel(label: 'Data', rule: false),
          const _ExportRidesTile(),
          const _RelabelPlacesTile(),

          const SectionLabel(label: 'About', rule: false),
          _SettingsTile(
            title: 'ThrottlePath',
            subtitle: _aboutLine(ref.watch(appVersionProvider).valueOrNull),
            onTap: () {},
          ),
        ],
      ),
    );
  }
}

/// The About row's single line, with the version dropped entirely when it isn't
/// known yet (or on a platform that won't answer) rather than shown as a
/// placeholder. The row is only ever read for one reason — to quote the version
/// somewhere — so a wrong number there is worse than no number, and the gap
/// lasts one frame on the way to a tab the rider had to navigate to.
String _aboutLine(String? version) => version == null
    ? 'Rides are stored on this phone only.'
    : 'Version $version · rides are stored on this phone only.';

// `_ThemeTile` and `_ThemeSegment` are gone (spec 8.4). Theme is a value row like
// every other setting now, opening `showThemePickerSheet` — see
// `theme_picker_sheet.dart` for why the inline three-up control had to go and why
// the sheet has no preview.

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

// `_SectionLabel` moved to `hairline_row.dart` as `SectionLabel` — it was the
// same widget the History month headers wanted, so both now share one, with
// `rule: false` here (the first row's own hairline already separates the group).

/// The value shown at the right of a tap-to-cycle row.
///
/// Amber (spec 8.2), and the only amber left in the list now that the icon tiles
/// are gone. That is not a contradiction of "one accent per screen": every value
/// here is the *state* of its row, and a settings list is read by scanning down
/// that right-hand edge. The accent marks the column a rider is actually looking
/// at rather than eight decorations they aren't.
class _ValueText extends StatelessWidget {
  const _ValueText(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    return ExcludeSemantics(
      child: Text(
        text,
        style: TextStyle(
          color: cx.accentInk,
          fontSize: 13,
          fontWeight: FontWeight.w500,
        ),
      ),
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

/// Minimum height for a settings row. A *constraint*, not a height — the a11y
/// pass had to undo fixed heights across this list once already, because a row
/// pinned to 48dp clips its own subtitle the moment the system text scale moves.
const double _kRowMinHeight = 48;

class _SettingsTile extends StatelessWidget {
  const _SettingsTile({
    required this.title,
    this.subtitle,
    this.trailing,
    required this.onTap,
    this.semanticValue,
    this.semanticToggled,
  });

  final String title;

  /// One line of consequence, for settings whose title doesn't say what turning
  /// them on actually costs or does. Deliberately absent on the rows whose value
  /// already says it (spec 8.3) — a description that restates the value is one
  /// more line to skip past on the way to the one that doesn't.
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
    final t = Theme.of(context).textTheme;
    return Semantics(
      button: semanticToggled == null,
      toggled: semanticToggled,
      label: title,
      value: semanticValue,
      hint: subtitle,
      child: HairlineRow(
        onTap: onTap,
        minHeight: _kRowMinHeight,
        child: Row(
          children: [
            Expanded(
              child: ExcludeSemantics(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(title, style: t.bodyMedium),
                    if (subtitle != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 3, right: 8),
                        child: Text(subtitle!, style: t.bodySmall),
                      ),
                  ],
                ),
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 12),
              trailing!,
            ],
          ],
        ),
      ),
    );
  }
}
