import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:throttlepath/theme/app_theme.dart';

/// WCAG 2.1 contrast ratio. `Color.computeLuminance()` is already the WCAG
/// relative-luminance formula, so this is just the ratio on top of it.
double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// The UX audit's headline finding was amber-as-text at 1.9:1 on the light
/// theme — the distance on every card, unreadable in sunlight. These tests
/// pin every text token against every ground it can land on, so a palette
/// tweak can never quietly reintroduce that.
///
/// AA body text is 4.5:1. We hold *everything* to it, including the 12sp
/// tertiary labels, because a rider reads this at arm's length in daylight.
const double _aa = 4.5;

void main() {
  for (final entry in {
    'dark': AppPalette.dark,
    'light': AppPalette.light,
  }.entries) {
    final theme = entry.key;
    final p = entry.value;

    group('$theme theme', () {
      // Every ground a widget can paint text onto.
      final grounds = <String, Color>{
        'canvas': p.canvas,
        'surface': p.surface,
        'surfaceRaised': p.surfaceRaised,
      };

      // Every token the app is allowed to put in a TextStyle.color.
      final inks = <String, Color>{
        'textBright': p.textBright,
        'textDim': p.textDim,
        'textTertiary': p.textTertiary,
        'accentInk': p.accentInk,
        'dangerInk': p.dangerInk,
        'positiveInk': p.positiveInk,
        'peak': p.peak,
      };

      for (final ink in inks.entries) {
        for (final ground in grounds.entries) {
          test('${ink.key} on ${ground.key} clears AA', () {
            final ratio = _contrast(ink.value, ground.value);
            expect(
              ratio,
              greaterThanOrEqualTo(_aa),
              reason: '$theme ${ink.key} on ${ground.key} is '
                  '${ratio.toStringAsFixed(2)}:1, below AA ($_aa:1)',
            );
          });
        }
      }

      // Ink placed *on* a filled button must clear AA against the fill.
      for (final fill in {
        'accent': p.accent,
        'danger': p.danger,
        'positive': p.positive,
      }.entries) {
        test('onAccent on a ${fill.key} fill clears AA', () {
          final ratio = _contrast(p.onAccent, fill.value);
          expect(
            ratio,
            greaterThanOrEqualTo(_aa),
            reason: '$theme onAccent on ${fill.key} is '
                '${ratio.toStringAsFixed(2)}:1, below AA ($_aa:1)',
          );
        });
      }

      test('border is visible against every surface', () {
        // Hairlines are not text, so AA does not apply — but an invisible
        // divider is a bug, and both themes shipped one: dark border was
        // 1.03:1 on surfaceRaised, light was 1.13:1 on canvas.
        for (final ground in grounds.entries) {
          final ratio = _contrast(p.border, ground.value);
          expect(
            ratio,
            greaterThan(1.15),
            reason: '$theme border on ${ground.key} is only '
                '${ratio.toStringAsFixed(3)}:1 — effectively invisible',
          );
        }
      });
    });
  }

  group('colour rules', () {
    test('raw accent is NOT safe as text on light — this is why accentInk '
        'exists', () {
      // Guards the rule rather than the value: if someone "simplifies"
      // accentInk back to accent, this test explains what breaks.
      expect(
        _contrast(AppPalette.light.accent, AppPalette.light.canvas),
        lessThan(_aa),
      );
      expect(
        _contrast(AppPalette.light.accentInk, AppPalette.light.canvas),
        greaterThanOrEqualTo(_aa),
      );
    });

    test('peak is not red — red means irreversible, nothing else', () {
      for (final p in [AppPalette.dark, AppPalette.light]) {
        expect(p.peak, isNot(p.danger));
        expect(p.peak, isNot(p.dangerInk));
      }
    });

    test('both palettes carry every token distinctly typed', () {
      // A copyWith/lerp that drops a field silently would show up here as a
      // dark token leaking into the light palette.
      expect(AppPalette.dark.brightness, Brightness.dark);
      expect(AppPalette.light.brightness, Brightness.light);
      expect(AppPalette.dark.canvas, isNot(AppPalette.light.canvas));
      expect(AppPalette.dark.peak, isNot(AppPalette.light.peak));
      expect(AppPalette.dark.textBright, isNot(AppPalette.light.textBright));
    });

    test('lerp preserves every field at both ends', () {
      final a = AppPalette.dark;
      final b = AppPalette.light;
      expect(a.lerp(b, 0.0).canvas, a.canvas);
      expect(a.lerp(b, 1.0).canvas, b.canvas);
      expect(a.lerp(b, 0.0).peak, a.peak);
      expect(a.lerp(b, 1.0).peak, b.peak);
      expect(a.lerp(b, 0.0).surfaceRaised, a.surfaceRaised);
      expect(a.lerp(b, 1.0).textTertiary, b.textTertiary);
      expect(a.lerp(b, 1.0).positiveInk, b.positiveInk);
    });
  });

  group('theme wiring', () {
    test('no app bar inherits a Material surface tint', () {
      // The light app bar rendered lavender because M3 tints elevated
      // surfaces with ColorScheme.surfaceTint, which defaulted to Material's
      // own primary. Killing the tint is the actual fix for F32.
      for (final build in [buildDarkTheme, buildLightTheme]) {
        final t = build();
        expect(t.appBarTheme.surfaceTintColor, Colors.transparent);
        expect(t.colorScheme.surfaceTint, Colors.transparent);
        expect(t.cardTheme.surfaceTintColor, Colors.transparent);
        expect(t.dialogTheme.surfaceTintColor, Colors.transparent);
        expect(t.appBarTheme.backgroundColor,
            t.extension<AppPalette>()!.canvas);
      }
    });

    test('the type scale exists and respects the 12sp floor', () {
      for (final build in [buildDarkTheme, buildLightTheme]) {
        final text = build().textTheme;
        expect(text.displayLarge!.fontSize, 64);
        expect(text.displayMedium!.fontSize, 34);
        expect(text.titleMedium!.fontSize, 15);
        expect(text.bodyMedium!.fontSize, 13);
        expect(text.labelSmall!.fontSize, kMinFontSize);
      }
    });

    test('every Material text role survives the overlay', () {
      // The design names six roles; Material dereferences a dozen. Replacing
      // the TextTheme wholesale (rather than copyWith-ing onto the base) nulls
      // the rest and crashes ListTile/TextButton at build time.
      for (final build in [buildDarkTheme, buildLightTheme]) {
        final t = build().textTheme;
        final roles = <String, TextStyle?>{
          'displayLarge': t.displayLarge,
          'displayMedium': t.displayMedium,
          'displaySmall': t.displaySmall,
          'headlineLarge': t.headlineLarge,
          'headlineMedium': t.headlineMedium,
          'headlineSmall': t.headlineSmall,
          'titleLarge': t.titleLarge,
          'titleMedium': t.titleMedium,
          'titleSmall': t.titleSmall,
          'bodyLarge': t.bodyLarge,
          'bodyMedium': t.bodyMedium,
          'bodySmall': t.bodySmall,
          'labelLarge': t.labelLarge,
          'labelMedium': t.labelMedium,
          'labelSmall': t.labelSmall,
        };
        for (final role in roles.entries) {
          expect(role.value, isNotNull, reason: '${role.key} is null');
          expect(role.value!.fontFamily, 'Inter',
              reason: '${role.key} lost Inter');
          // A null fontSize is correct for roles the design does not pin:
          // Theme.localize merges Typography's geometry in later. Only the
          // sizes we set ourselves are checked against the floor.
          if (role.value!.fontSize != null) {
            expect(
              role.value!.fontSize,
              greaterThanOrEqualTo(kMinFontSize),
              reason: '${role.key} is below the ${kMinFontSize}sp floor',
            );
          }
        }
      }
    });

    test('numeric styles carry tabular figures', () {
      final text = buildDarkTheme().textTheme;
      for (final style in [
        text.displayLarge,
        text.displayMedium,
        text.headlineSmall,
      ]) {
        expect(style!.fontFeatures, contains(const FontFeature.tabularFigures()));
      }
    });
  });
}
