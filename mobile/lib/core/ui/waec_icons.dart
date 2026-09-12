import 'package:flutter/material.dart';

/// Brand crest glyph (teal shield + check) used on the Auth/About headers in
/// the WAEC Direct Figma design. Drawn with [CustomPaint] from raw [Path]
/// data so we avoid a binary asset dependency.
class WaecCrest extends StatelessWidget {
  const WaecCrest({super.key, this.size = 38, this.color = const Color(0xFF00D4B1)});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: CustomPaint(painter: _CrestPainter(color: color)),
      );
}

/// Convenience accessor mirroring the Figma icon set.
class WaecIcons {
  const WaecIcons._();
  static const crest = WaecCrest();
}

class _CrestPainter extends CustomPainter {
  const _CrestPainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 38;
    final paintFill = Paint()
      ..color = color.withValues(alpha: 0.18)
      ..style = PaintingStyle.fill;
    final paintStroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8 * s
      ..strokeJoin = StrokeJoin.round;
    final check = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2 * s
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final shield = Path()
      ..moveTo(19 * s, 4 * s)
      ..lineTo(6 * s, 10 * s)
      ..lineTo(6 * s, 20 * s)
      ..cubicTo(6 * s, 27.2 * s, 11.8 * s, 33.8 * s, 19 * s, 35.5 * s)
      ..cubicTo(26.2 * s, 33.8 * s, 32 * s, 27.2 * s, 32 * s, 20 * s)
      ..lineTo(32 * s, 10 * s)
      ..close();
    canvas.drawPath(shield, paintFill);
    canvas.drawPath(shield, paintStroke);
    canvas.drawPath(
      Path()
        ..moveTo(13 * s, 19 * s)
        ..lineTo(17 * s, 23 * s)
        ..lineTo(25 * s, 15 * s),
      check,
    );
    final dot = Path()
      ..addOval(Rect.fromCircle(center: Offset(19 * s, 19 * s), radius: 4.5 * s));
    canvas.drawPath(
      dot,
      Paint()
        ..color = color.withValues(alpha: 0.4)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1 * s,
    );
  }

  @override
  bool shouldRepaint(covariant _CrestPainter old) => old.color != color;
}
