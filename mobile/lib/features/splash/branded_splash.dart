import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';

import '../../core/brand.dart';
import '../../core/design_tokens.dart';

/// Branded loading screen shown immediately after the native splash.
///
/// The native (pre-Android-12) splash is a static bitmap, so it carries the
/// logo + name + description + a static progress bar; this widget continues
/// seamlessly (the native splash is preserved until our first frame via
/// `FlutterNativeSplash.preserve`) with a *live* progress bar and rotating
/// status messages, then hands off to the auth gate.
///
/// All copy, colors and asset paths come from [Brand] — the single source of
/// truth (assets/brand_kit.json).
class BrandedSplash extends StatefulWidget {
  const BrandedSplash({super.key, required this.onDone});

  /// Called once the splash has finished (minimum display elapsed).
  final VoidCallback onDone;

  @override
  State<BrandedSplash> createState() => _BrandedSplashState();
}

class _BrandedSplashState extends State<BrandedSplash>
    with SingleTickerProviderStateMixin {
  static const _minDisplay = Duration(milliseconds: 2200);

  late final AnimationController _progress;
  bool _removedNativeSplash = false;
  bool _statusListenerAttached = true;

  @override
  void initState() {
    super.initState();
    _progress = AnimationController(vsync: this, duration: _minDisplay)
      ..forward();
    _progress.addStatusListener(_onStatus);
  }

  void _onStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    _progress.removeStatusListener(_onStatus);
    _statusListenerAttached = false;
    widget.onDone();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_removedNativeSplash) return;
    _removedNativeSplash = true;
    // Hand off from the native splash after our first frame so there is no
    // white flash between the two.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      FlutterNativeSplash.remove();
    });
  }

  @override
  void dispose() {
    if (_statusListenerAttached) _progress.removeStatusListener(_onStatus);
    _progress.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final brand = BrandScope.of(context);
    final statuses = brand.splashStatuses;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      // White system bars too: the native launch window paints white behind
      // both bars, and the root AnnotatedRegion (navy) only re-asserts itself
      // once this splash unmounts and the auth gate takes over.
      value: kSplashSystemBarStyle,
      child: Scaffold(
        // White splash (reported request): matches the white native splash so
        // the two phases read as one. Navy text carries the contrast instead.
        backgroundColor: Colors.white,
        body: SafeArea(
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Brand logo: the glyph master is dark, so it stays visible
                // directly on the white splash. A subtle border keeps the white
                // plate defined against the white background.
                Container(
                  width: 132,
                  height: 132,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: const Color(0xFFE2E8F0),
                      width: 1.5,
                    ),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x0D0A2540),
                        blurRadius: 16,
                        offset: Offset(0, 4),
                      ),
                    ],
                  ),
                  alignment: Alignment.center,
                  child: Image.asset(
                    brand.logoAsset,
                    width: 92,
                    filterQuality: FilterQuality.high,
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  brand.appName,
                  style: TextStyle(
                    color: WaecColors.navy,
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    fontFamily: brand.fontSans,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  brand.splashDescription,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: WaecColors.textSecondaryLight,
                    fontSize: 14,
                    fontFamily: brand.fontSans,
                  ),
                ),
                const SizedBox(height: 28),
                // Live progress bar (brand teal on a translucent track).
                AnimatedBuilder(
                  animation: _progress,
                  builder: (context, _) {
                    final value = _progress.value;
                    final index = (value * statuses.length).floor().clamp(
                      0,
                      statuses.length - 1,
                    );
                    return Column(
                      children: [
                        SizedBox(
                          width: 160,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(999),
                            child: LinearProgressIndicator(
                              value: value,
                              minHeight: 4,
                              backgroundColor: const Color(0xFFE2E8F0),
                              valueColor: AlwaysStoppedAnimation<Color>(
                                brand.teal,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          statuses[index],
                          style: TextStyle(
                            color: WaecColors.textSecondaryLight,
                            fontSize: 12,
                            fontFamily: brand.fontSans,
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
