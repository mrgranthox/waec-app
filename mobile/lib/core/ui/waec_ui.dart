import 'package:flutter/material.dart';

/// Shared visual primitives lifted from the WAEC Direct Figma screens
/// (docs/WAEC Result Verification App). Keep these design-token driven so
/// every ported screen renders the same card / label / badge language.

/// Uppercase tracked field label (Figma `FieldLabel`).
Widget waecFieldLabel(String text) => Text(
      text.toUpperCase(),
      style: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.2,
        color: Color(0xFF64748B),
      ),
    );

/// Figma card surface: white, 16px radius, 1px slate border, soft shadow.
BoxDecoration waecCardDecoration({Color background = Colors.white}) =>
    BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: const Color(0xFFE2E8F0)),
      boxShadow: const [
        BoxShadow(
          color: Color(0x0F0A2540),
          blurRadius: 16,
          offset: Offset(0, 2),
        ),
      ],
    );

/// Inset input/display box: light fill with a 1.5px tracked border.
BoxDecoration waecFieldBoxDecoration({
  Color background = const Color(0xFFF8FAFC),
  Color borderColor = const Color(0xFFE2E8F0),
}) =>
    BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: borderColor, width: 1.5),
    );

/// Tiny status chip (LOCKED / Saved Local / …).
class WaecChip extends StatelessWidget {
  const WaecChip({
    super.key,
    required this.label,
    this.foreground = const Color(0xFF00856F),
    this.background = const Color(0xFFF0FDF9),
    this.borderColor = const Color(0xFFCCFBF1),
  });

  final String label;
  final Color foreground;
  final Color background;
  final Color borderColor;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: borderColor),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.4,
            color: foreground,
          ),
        ),
      );
}

/// Navy header band used at the top of the Home / History pages.
class WaecNavyHeader extends StatelessWidget {
  const WaecNavyHeader({
    super.key,
    required this.eyebrow,
    required this.title,
    this.subtitle,
    this.trailing,
    this.titleIsMono = false,
  });

  final String eyebrow;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final bool titleIsMono;

  @override
  Widget build(BuildContext context) => Container(
        color: const Color(0xFF0A2540),
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    eyebrow.toUpperCase(),
                    style: const TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 1.6,
                      color: Color(0xCC00D4B1),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    title,
                    style: titleIsMono
                        ? const TextStyle(
                            fontFamily: 'JetBrains Mono',
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 1.4,
                            color: Colors.white,
                          )
                        : const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      subtitle!,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0x66FFFFFF),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            ?trailing,
          ],
        ),
      );
}

/// Mint "Authenticated" pill shown on the session bar.
class WaecAuthPill extends StatelessWidget {
  const WaecAuthPill({super.key, this.label = 'Authenticated'});
  final String label;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0x1F00D4B1),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0x4000D4B1)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 6,
              height: 6,
              decoration: const BoxDecoration(
                color: Color(0xFF00D4B1),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: Color(0xFF00D4B1),
              ),
            ),
          ],
        ),
      );
}
