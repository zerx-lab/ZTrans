import 'package:flutter/material.dart';
import 'package:rinf/rinf.dart';
import 'package:window_manager/window_manager.dart';
import 'src/bindings/bindings.dart';
import 'src/pages/home_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  const windowOptions = WindowOptions(
    size: Size(1000, 660),
    minimumSize: Size(720, 480),
    center: true,
    title: 'ZTrans',
    titleBarStyle: TitleBarStyle.hidden,
    windowButtonVisibility: false,
    backgroundColor: Colors.transparent,
    skipTaskbar: false,
  );
  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });

  await initializeRust(assignRustSignal);
  runApp(const ZTransApp());
}

class ZTransApp extends StatelessWidget {
  const ZTransApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ZTrans',
      debugShowCheckedModeBanner: false,
      theme: _buildTheme(Brightness.light),
      darkTheme: _buildTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      home: const HomePage(),
    );
  }

  ThemeData _buildTheme(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF4285F4),
        brightness: brightness,
      ),
      fontFamily: 'sans-serif',
      inputDecorationTheme: const InputDecorationTheme(
        border: InputBorder.none,
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStateProperty.all(
          isDark
              ? Colors.white.withValues(alpha: 0.2)
              : Colors.black.withValues(alpha: 0.15),
        ),
      ),
    );
  }
}
