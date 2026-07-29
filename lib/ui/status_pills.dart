/// The status chips and hazard rail the telemetry sheet uses to say what the
/// engine is doing — acquiring, paused, or blacked out.
library;

import 'package:flutter/material.dart';

/// Status pill with a leading dot (e.g. "● ACQUIRING GPS…") shown in place of
/// the speed number.
class StatusPill extends StatelessWidget {
  const StatusPill({
    super.key,
    required this.label,
    required this.dotColor,
    required this.textColor,
    required this.borderColor,
  });

  final String label;
  final Color dotColor;
  final Color textColor;
  final Color borderColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Text(
            label,
            style: TextStyle(
              color: textColor,
              fontSize: 14,
              letterSpacing: 1,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

/// Small outlined status pill (PAUSED / GET READY) shown under the hero number.
class OutlinePill extends StatelessWidget {
  const OutlinePill({
    super.key,required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 12,
          letterSpacing: 1.5,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// Filled status chip (PAUSED / GPS SIGNAL LOST). Deliberately louder than
/// [OutlinePill]: the paused screen used to differ from the recording one by a
/// single small outlined badge, which is how riders finished a stint believing it
/// had been captured (F12).
class FilledPill extends StatelessWidget {
  const FilledPill({
    super.key,
    required this.label,
    required this.background,
    required this.foreground,
  });

  final String label;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 7),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: foreground,
          fontSize: 13,
          letterSpacing: 1.4,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

/// Diagonal hazard stripes across the top edge of the telemetry sheet, shown
/// whenever the ride clock is frozen. The cue that works at arm's length on a
/// handlebar mount: colour and texture, no reading required.
class StripedRail extends StatelessWidget {
  const StripedRail({
    super.key,required this.color});

  final Color color;

  static const double height = 6;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(painter: _StripePainter(color)),
    );
  }
}

class _StripePainter extends CustomPainter {
  const _StripePainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // A wash under the stripes so the rail still reads as a solid band from far
    // enough away that the individual stripes blur together.
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = color.withValues(alpha: 0.3),
    );
    final paint = Paint()
      ..color = color
      ..strokeWidth = 4;
    // 45°, starting off the left edge so the first stripe is a whole one.
    for (var x = -size.height; x < size.width + size.height; x += 12) {
      canvas.drawLine(
        Offset(x, size.height),
        Offset(x + size.height, 0),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_StripePainter oldDelegate) => oldDelegate.color != color;
}
