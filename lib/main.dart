import 'package:flutter/material.dart';
import 'package:rinf/rinf.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import 'src/bindings/bindings.dart';
import 'src/pages/home_page.dart';
import 'src/settings/settings_provider.dart';
import 'src/themes/app_themes.dart';

/// 截图进行中时置 true，阻止 onWindowBlur 隐藏窗口
bool appCapturing = false;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  // 先建立 Rust 桥接，暂不显示窗口
  await initializeRust(assignRustSignal);

  // 立刻挂上监听器（在任何 await 之前），防止 Rust 极快发出信号时被广播流丢弃
  final instanceReadyFuture = InstanceReady.rustSignalStream.first;

  final settings = SettingsProvider();
  await settings.load();

  // 等待 Rust 确认这是主实例再显示窗口。
  // 委托实例会调 process::exit(0)，进程在此之前已消亡，不会到达这一行。
  await instanceReadyFuture;

  const windowOptions = WindowOptions(
    titleBarStyle: TitleBarStyle.hidden,
    windowButtonVisibility: false,
  );
  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
    await windowManager.setPreventClose(true);
  });

  runApp(ZTransApp(settings: settings));
}

class ZTransApp extends StatefulWidget {
  const ZTransApp({super.key, required this.settings});

  final SettingsProvider settings;

  @override
  State<ZTransApp> createState() => _ZTransAppState();
}

class _ZTransAppState extends State<ZTransApp>
    with WindowListener, TrayListener {
  /// 记录窗口最近一次变为可见的时刻，用于保护 onWindowBlur 不会在窗口刚显示后立刻隐藏它
  DateTime _lastShownAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    // 启动保护：初始化时立刻记录 show 时刻，防止 Wayland 焦点竞争导致窗口刚出现就被 blur 隐藏
    _lastShownAt = DateTime.now();
    widget.settings.addListener(_onSettingsChanged);
    windowManager.addListener(this);
    _initTray();
  }

  @override
  void dispose() {
    widget.settings.removeListener(_onSettingsChanged);
    windowManager.removeListener(this);
    trayManager.removeListener(this);
    super.dispose();
  }

  Future<void> _initTray() async {
    try {
      trayManager.addListener(this);
      await trayManager.setIcon('assets/tray_icon.png');
      await trayManager.setToolTip('ZTrans');
      await trayManager.setContextMenu(Menu(items: [
        MenuItem(key: 'show', label: '显示'),
        MenuItem.separator(),
        MenuItem(key: 'quit', label: '退出'),
      ]));
    } catch (e, st) {
      debugPrint('[ZTrans] 托盘初始化失败: $e\n$st');
    }
  }

  // ── 托盘事件 ──────────────────────────────────────────

  @override
  void onTrayIconMouseDown() {
    windowManager.isVisible().then((visible) {
      if (visible) {
        windowManager.hide();
      } else {
        windowManager.show().then((_) => windowManager.focus());
      }
    });
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        windowManager.show().then((_) => windowManager.focus());
      case 'quit':
        // 解除防关闭，然后关闭窗口，让 Rinf/进程正常退出
        windowManager.setPreventClose(false).then((_) => windowManager.close());
    }
  }

  // ── 窗口事件 ──────────────────────────────────────────

  @override
  void onWindowShow() {
    _lastShownAt = DateTime.now();
  }

  /// 失焦隐藏到托盘；截图进行中或窗口刚显示（500ms 内）时跳过
  @override
  void onWindowBlur() {
    if (appCapturing) return;
    // KDE Wayland 上焦点竞争：窗口刚出现时 blur 事件可能紧随 show 而来，忽略之
    if (DateTime.now().difference(_lastShownAt) < const Duration(milliseconds: 500)) return;
    windowManager.hide();
  }

  /// 关闭按钮（TitleBar 已改为 windowManager.hide()，此处作为保险）
  @override
  void onWindowClose() {
    windowManager.hide();
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
