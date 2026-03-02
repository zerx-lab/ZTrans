import 'package:flutter/material.dart';

enum AppThemeMode { light, dark, oneDarkPro }

class AppThemes {
  AppThemes._();

  static ThemeData getTheme(AppThemeMode mode) {
    switch (mode) {
      case AppThemeMode.light:
        return light();
      case AppThemeMode.dark:
        return dark();
      case AppThemeMode.oneDarkPro:
        return oneDarkPro();
    }
  }

  static ThemeData light() {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF4285F4),
        brightness: Brightness.light,
      ),
      fontFamily: 'sans-serif',
      inputDecorationTheme: const InputDecorationTheme(border: InputBorder.none),
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStateProperty.all(Colors.black.withValues(alpha: 0.15)),
      ),
    );
  }

  static ThemeData dark() {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF4285F4),
        brightness: Brightness.dark,
      ),
      fontFamily: 'sans-serif',
      inputDecorationTheme: const InputDecorationTheme(border: InputBorder.none),
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStateProperty.all(Colors.white.withValues(alpha: 0.2)),
      ),
    );
  }

  static ThemeData oneDarkPro() {
    // One Dark Pro 调色板（atom-one-dark-pro）
    const bg = Color(0xFF282c34);
    const surface = Color(0xFF21252b);
    const surfaceLow = Color(0xFF23272e);
    const surfaceContainer = Color(0xFF2c313c);
    const fg = Color(0xFFabb2bf);
    const primary = Color(0xFF61afef);
    const secondary = Color(0xFF98c379);
    const errorColor = Color(0xFFe06c75);
    const comment = Color(0xFF5c6370);
    const outline = Color(0xFF3e4451);
    const outlineVariant = Color(0xFF353b45);

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: ColorScheme(
        brightness: Brightness.dark,
        primary: primary,
        onPrimary: bg,
        primaryContainer: const Color(0xFF3a3f4b),
        onPrimaryContainer: primary,
        secondary: secondary,
        onSecondary: bg,
        secondaryContainer: surfaceContainer,
        onSecondaryContainer: secondary,
        tertiary: const Color(0xFFc678dd),
        onTertiary: bg,
        tertiaryContainer: surfaceContainer,
        onTertiaryContainer: const Color(0xFFc678dd),
        error: errorColor,
        onError: bg,
        errorContainer: const Color(0xFF3d1a1a),
        onErrorContainer: errorColor,
        surface: surface,
        onSurface: fg,
        surfaceContainerLowest: bg,
        surfaceContainerLow: surfaceLow,
        surfaceContainer: surfaceContainer,
        surfaceContainerHigh: const Color(0xFF333842),
        surfaceContainerHighest: const Color(0xFF3a3f4b),
        onSurfaceVariant: comment,
        outline: outline,
        outlineVariant: outlineVariant,
        shadow: Colors.black,
        scrim: Colors.black,
        inverseSurface: fg,
        onInverseSurface: bg,
        inversePrimary: const Color(0xFF1a5f8f),
      ),
      fontFamily: 'sans-serif',
      inputDecorationTheme: const InputDecorationTheme(border: InputBorder.none),
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStateProperty.all(comment.withValues(alpha: 0.5)),
      ),
    );
  }
}
