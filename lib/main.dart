import 'package:flutter/material.dart';
import 'package:rinf/rinf.dart';
import 'package:window_manager/window_manager.dart';
import 'src/bindings/bindings.dart';
import 'src/pages/home_page.dart';
import 'src/settings/settings_provider.dart';
import 'src/themes/app_themes.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  const windowOptions = WindowOptions(
    titleBarStyle: TitleBarStyle.hidden,
    windowButtonVisibility: false,
  );
  await windowManager.waitUntilReadyToShow(windowOptions);
  await initializeRust(assignRustSignal);
  final settings = SettingsProvider();
  await settings.load();
  runApp(ZTransApp(settings: settings));
}

class ZTransApp extends StatefulWidget {
  const ZTransApp({super.key, required this.settings});

  final SettingsProvider settings;

  @override
  State<ZTransApp> createState() => _ZTransAppState();
}

class _ZTransAppState extends State<ZTransApp> {
  @override
  void initState() {
    super.initState();
    widget.settings.addListener(_onSettingsChanged);
  }

  @override
  void dispose() {
    widget.settings.removeListener(_onSettingsChanged);
    super.dispose();
  }

  void _onSettingsChanged() => setState(() {});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ZTrans',
      debugShowCheckedModeBanner: false,
      theme: AppThemes.getTheme(widget.settings.themeMode),
      home: HomePage(settings: widget.settings),
    );
  }
}
