# R8/ProGuard rules for the release build (plan §4.2).
#
# Flutter ships its own rules (io.flutter.* keep-classes) via the Flutter Gradle
# plugin, so this file only adds what the app's own native surface needs.
# Everything here is a *keep* rule: Dart-side names are obfuscated by
# --obfuscate and never reach R8, so shrinking aggressively is safe.

# SQLCipher / SQLCipher-for-Android loads its JNI bridge reflectively; without
# this, R8 strips it and the encrypted archive silently fails to open at
# runtime on release builds only (the exact class of bug §4.3 guards against).
-keep class net.sqlcipher.** { *; }
-keep class net.sqlcipher.database.** { *; }
-dontwarn net.sqlcipher.**

# flutter_secure_storage delegates to Android Keystore via reflection.
-keep class com.it_nomtech.flutter_secure_storage.** { *; }
-dontwarn com.it_nomtech.flutter_secure_storage.**

# JNI-invoked entrypoints must survive renaming.
-keepclasseswithmembernames class * {
    native <methods>;
}

# Plugins registered by GeneratedPluginRegistrant are looked up by name.
-keep class io.flutter.plugins.GeneratedPluginRegistrant { *; }

# The Activity Flutter launches by name from the manifest.
-keep class * extends io.flutter.embedding.android.FlutterActivity { *; }

# Never inline or strip the platform channel handlers.
-keep class * implements io.flutter.plugin.common.MethodChannel$MethodHandler { *; }

# Keep line numbers out of release builds: they leak source structure into
# crash reports (§4.2's "symbols unrecoverable" check).
-renamesourcefileattribute ""
-optimizations !code/simplification/arithmetic,!code/simplification/cast,!field/*,!class/merging/*
