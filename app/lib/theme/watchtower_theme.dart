import 'package:flutter/material.dart';

/// The visual language for vigilant-core: calm, dense enough for infrastructure
/// data, and explicit about state without relying on colour alone.
abstract final class vigilant-corePalette {
  static const background = Color(0xFF0B1020);
  static const surface = Color(0xFF11182A);
  static const surfaceRaised = Color(0xFF19243A);
  static const surfaceHighest = Color(0xFF202D46);
  static const border = Color(0xFF2A3852);
  static const accent = Color(0xFF65A9FF);
  static const accentStrong = Color(0xFF2F80ED);
  static const healthy = Color(0xFF43D6A4);
  static const warning = Color(0xFFFFC857);
  static const critical = Color(0xFFFF6B7A);
  static const ink = Color(0xFFF4F7FC);
  static const inkMuted = Color(0xFFAAB7CB);

  static const lightBackground = Color(0xFFF5F7FB);
  static const lightSurface = Color(0xFFFFFFFF);
  static const lightBorder = Color(0xFFD9E1ED);
  static const lightInk = Color(0xFF162033);
  static const lightInkMuted = Color(0xFF5D6A7E);
}

ThemeData buildvigilant-coreTheme({Brightness brightness = Brightness.dark}) {
  final dark = brightness == Brightness.dark;
  final background = dark
      ? vigilant-corePalette.background
      : vigilant-corePalette.lightBackground;
  final surface = dark
      ? vigilant-corePalette.surface
      : vigilant-corePalette.lightSurface;
  final surfaceRaised = dark
      ? vigilant-corePalette.surfaceRaised
      : const Color(0xFFEDF2F9);
  final surfaceHighest = dark
      ? vigilant-corePalette.surfaceHighest
      : const Color(0xFFE6EDF7);
  final border = dark
      ? vigilant-corePalette.border
      : vigilant-corePalette.lightBorder;
  final ink = dark ? vigilant-corePalette.ink : vigilant-corePalette.lightInk;
  final muted = dark
      ? vigilant-corePalette.inkMuted
      : vigilant-corePalette.lightInkMuted;

  final scheme =
      ColorScheme.fromSeed(
        seedColor: vigilant-corePalette.accent,
        brightness: brightness,
      ).copyWith(
        primary: dark
            ? vigilant-corePalette.accent
            : vigilant-corePalette.accentStrong,
        onPrimary: dark ? vigilant-corePalette.background : Colors.white,
        secondary: vigilant-corePalette.healthy,
        onSecondary: dark ? vigilant-corePalette.background : Colors.white,
        error: vigilant-corePalette.critical,
        onError: Colors.white,
        surface: surface,
        onSurface: ink,
        surfaceContainerLowest: background,
        surfaceContainerLow: surface,
        surfaceContainer: surfaceRaised,
        surfaceContainerHigh: surfaceHighest,
        surfaceContainerHighest: dark
            ? const Color(0xFF263653)
            : const Color(0xFFDCE6F3),
        outline: border,
        outlineVariant: border.withValues(alpha: dark ? 0.72 : 0.9),
        onSurfaceVariant: muted,
      );

  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: background,
  );

  return base.copyWith(
    textTheme: base.textTheme.copyWith(
      headlineSmall: base.textTheme.headlineSmall?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -0.4,
      ),
      titleLarge: base.textTheme.titleLarge?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -0.2,
      ),
      titleMedium: base.textTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.w700,
      ),
      titleSmall: base.textTheme.titleSmall?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: 0.1,
      ),
      bodyLarge: base.textTheme.bodyLarge?.copyWith(height: 1.35),
      bodyMedium: base.textTheme.bodyMedium?.copyWith(height: 1.35),
      bodySmall: base.textTheme.bodySmall?.copyWith(color: muted, height: 1.35),
      labelLarge: base.textTheme.labelLarge?.copyWith(
        fontWeight: FontWeight.w700,
      ),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: background,
      foregroundColor: ink,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: base.textTheme.titleLarge?.copyWith(
        color: ink,
        fontWeight: FontWeight.w700,
      ),
    ),
    cardTheme: CardThemeData(
      color: surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: border),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: surfaceRaised,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: scheme.primary, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: scheme.error),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: scheme.error, width: 1.5),
      ),
      labelStyle: TextStyle(color: muted),
      hintStyle: TextStyle(color: muted),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      height: 76,
      indicatorColor: scheme.primary.withValues(alpha: dark ? 0.18 : 0.12),
      labelTextStyle: WidgetStatePropertyAll(
        base.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700),
      ),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return IconThemeData(
          color: selected ? scheme.primary : muted,
          size: 22,
        );
      }),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: surfaceRaised,
      selectedColor: scheme.primary.withValues(alpha: 0.18),
      side: BorderSide(color: border),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      labelStyle: base.textTheme.labelLarge?.copyWith(color: ink),
      secondaryLabelStyle: base.textTheme.labelLarge?.copyWith(color: ink),
      padding: const EdgeInsets.symmetric(horizontal: 4),
    ),
    dividerTheme: DividerThemeData(color: border, space: 1, thickness: 1),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: surfaceHighest,
      contentTextStyle: base.textTheme.bodyMedium?.copyWith(color: ink),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: base.textTheme.labelLarge,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        side: BorderSide(color: border),
        textStyle: base.textTheme.labelLarge,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: scheme.primary,
        textStyle: base.textTheme.labelLarge,
      ),
    ),
    listTileTheme: ListTileThemeData(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      titleTextStyle: base.textTheme.titleMedium?.copyWith(color: ink),
      subtitleTextStyle: base.textTheme.bodySmall?.copyWith(color: muted),
      iconColor: muted,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      titleTextStyle: base.textTheme.titleLarge?.copyWith(color: ink),
      contentTextStyle: base.textTheme.bodyMedium?.copyWith(color: muted),
    ),
  );
}
