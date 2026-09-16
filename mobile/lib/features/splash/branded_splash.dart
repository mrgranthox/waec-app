import 'package:flutter/material.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';

import '../../core/brand.dart';

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

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Brand logo (transparent glyph master, rendered crisply).
              Image.asset(brand.logoAsset, width: 112, filterQuality: FilterQuality.high),
              const SizedBox(height: 24),
              Text(
                brand.appName,
                style: TextStyle(
                  color: brand.ink,
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
                  color: brand.muted,
                  fontSize: 14,
                  fontFamily: brand.fontSans,
                ),
              ),
              const SizedBox(height: 28),
              // Live progress bar (brand teal on brand border track).
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
                            backgroundColor: brand.border,
                            valueColor: AlwaysStoppedAnimation<Color>(brand.teal),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        statuses[index],
                        style: TextStyle(
                          color: brand.ink.withValues(alpha: .65),
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
    );
  }
}
