import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

/// A single compliance badge from the brand kit.
class BrandCompliance {
  const BrandCompliance({required this.label, required this.status});

  factory BrandCompliance.fromJson(Map<String, dynamic> json) =>
      BrandCompliance(label: json['label'] as String, status: json['status'] as String);

  final String label;
  final String status;
}

/// Support / contact details from the brand kit.
class BrandSupport {
  const BrandSupport({
    required this.dpoLabel,
    required this.dpoEmail,
    required this.officeLabel,
    required this.headOffice,
    required this.mapQuery,
  });

  factory BrandSupport.fromJson(Map<String, dynamic> json) => BrandSupport(
        dpoLabel: json['dpoLabel'] as String,
        dpoEmail: json['dpoEmail'] as String,
        officeLabel: json['officeLabel'] as String,
        headOffice: json['headOffice'] as String,
        mapQuery: json['mapQuery'] as String,
      );

  final String dpoLabel;
  final String dpoEmail;
  final String officeLabel;
  final String headOffice;
  final String mapQuery;
}

/// The WAEC Direct brand — the single source of truth for app identity.
///
/// Loaded once from `assets/brand_kit.json`. The same file is read by
/// `scripts/gen_brand_assets.sh` when generating the native icon/splash
/// masters, so the launcher icon, splash screen and every screen in the app
/// always agree.
///
/// Access the active brand via [BrandScope.of].
class Brand {
  const Brand({
    required this.appName,
    required this.displayName,
    required this.packageName,
    required this.version,
    required this.buildNumber,
    required this.androidApplicationId,
    required this.iosBundleId,
    required this.tagline,
    required this.splashDescription,
    required this.splashStatuses,
    required this.logoAsset,
    required this.splashAsset,
    required this.ink,
    required this.teal,
    required this.surface,
    required this.border,
    required this.muted,
    required this.danger,
    required this.amber,
    required this.fontSans,
    required this.fontMono,
    required this.organization,
    required this.publisher,
    required this.copyright,
    required this.platform,
    required this.minOs,
    required this.apiVersion,
    required this.support,
    required this.compliance,
  });

  /// Loads and parses `assets/brand_kit.json`.
  static Future<Brand> load() async {
    final raw = await rootBundle.loadString('assets/brand_kit.json');
    return Brand.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  factory Brand.fromJson(Map<String, dynamic> json) {
    final colors = (json['colors'] as Map<String, dynamic>).map(
      (k, v) => MapEntry(k, _parseColor(v as String)),
    );
    final fonts = json['fonts'] as Map<String, dynamic>;
    return Brand(
      appName: json['appName'] as String,
      displayName: json['displayName'] as String,
      packageName: json['packageName'] as String,
      version: json['version'] as String,
      buildNumber: json['buildNumber'] as String,
      androidApplicationId: json['androidApplicationId'] as String,
      iosBundleId: json['iosBundleId'] as String,
      tagline: json['tagline'] as String,
      splashDescription: json['splashDescription'] as String,
      splashStatuses: (json['splashStatuses'] as List<dynamic>)
          .cast<String>()
          .toList(growable: false),
      logoAsset: json['logo'] as String,
      splashAsset: json['splash'] as String,
      ink: colors['ink']!,
      teal: colors['teal']!,
      surface: colors['surface']!,
      border: colors['border']!,
      muted: colors['muted']!,
      danger: colors['danger']!,
      amber: colors['amber']!,
      fontSans: fonts['sans'] as String,
      fontMono: fonts['mono'] as String,
      organization: json['organization'] as String,
      publisher: json['publisher'] as String,
      copyright: json['copyright'] as String,
      platform: json['platform'] as String,
      minOs: json['minOs'] as String,
      apiVersion: json['apiVersion'] as String,
      support: BrandSupport.fromJson(json['support'] as Map<String, dynamic>),
      compliance: (json['compliance'] as List<dynamic>)
          .map((e) => BrandCompliance.fromJson(e as Map<String, dynamic>))
          .toList(growable: false),
    );
  }

  static Color _parseColor(String hex) {
    var value = hex.replaceFirst('#', '');
    if (value.length == 6) value = 'FF$value';
    return Color(int.parse(value, radix: 16));
  }

  // Identity
  final String appName;
  final String displayName;
  final String packageName;
  final String version;
  final String buildNumber;
  final String androidApplicationId;
  final String iosBundleId;

  // Copy
  final String tagline;
  final String splashDescription;

  /// Ordered status labels shown by the branded splash while it loads.
  final List<String> splashStatuses;

  // Assets
  final String logoAsset;
  final String splashAsset;

  // Colors
  final Color ink;
  final Color teal;
  final Color surface;
  final Color border;
  final Color muted;
  final Color danger;
  final Color amber;

  // Typography
  final String fontSans;
  final String fontMono;

  // Legal / metadata
  final String organization;
  final String publisher;
  final String copyright;
  final String platform;
  final String minOs;
  final String apiVersion;
  final BrandSupport support;
  final List<BrandCompliance> compliance;
}

/// Provides the loaded [Brand] to the whole widget tree.
class BrandScope extends InheritedWidget {
  const BrandScope({super.key, required this.brand, required super.child});

  final Brand brand;

  static Brand of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<BrandScope>()!.brand;

  @override
  bool updateShouldNotify(BrandScope oldWidget) => oldWidget.brand != brand;
}

