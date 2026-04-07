import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import '../themes/app_themes.dart';

enum TranslatorBackend { google, openai }

class SettingsProvider extends ChangeNotifier {
  static const _themeKey = 'app_theme';
  static const _backendKey = 'translator_backend';
  static const _openaiBaseUrlKey = 'openai_base_url';
  static const _openaiApiKeyKey = 'openai_api_key';
  static const _openaiModelKey = 'openai_model';
  static const _openaiThinkingKey = 'openai_thinking';
  static const _openaiSystemPromptKey = 'openai_system_prompt';
  static const _ocrModelKey = 'ocr_model';
  static const _useXdgShortcutsKey = 'use_xdg_shortcuts';

  AppThemeMode _themeMode = AppThemeMode.dark;
  TranslatorBackend _backend = TranslatorBackend.google;
  String _openaiBaseUrl = 'https://api.siliconflow.cn/v1';
  String _openaiApiKey = '';
  String _openaiModel = 'Qwen/Qwen3-8B';
  bool _openaiThinking = false;
  String _openaiSystemPrompt = '';
  String _ocrModel = 'deepseek-ai/DeepSeek-OCR';
  bool _useXdgShortcuts = false;

  /// 缓存的开机启动状态（从文件系统读取）
  bool _autostart = false;

  AppThemeMode get themeMode => _themeMode;
  TranslatorBackend get backend => _backend;
  String get openaiBaseUrl => _openaiBaseUrl;
  String get openaiApiKey => _openaiApiKey;
  String get openaiModel => _openaiModel;
  bool get openaiThinking => _openaiThinking;
  String get openaiSystemPrompt => _openaiSystemPrompt;
  String get ocrModel => _ocrModel;
  bool get useXdgShortcuts => _useXdgShortcuts;
  bool get autostart => _autostart;

  // ── XDG Autostart 路径 ────────────────────────────────────────────────────

  /// ~/.config/autostart/ztrans.desktop
  static File get _autostartFile {
    final home = Platform.environment['HOME'] ?? '/root';
    return File(p.join(home, '.config', 'autostart', 'ztrans.desktop'));
  }

  /// 解析当前可执行文件的路径，用于写入 autostart 文件的 Exec 字段。
  /// 优先使用 PATH 中的 ztrans（已通过包管理器安装），
  /// 若找不到则回退到当前进程的绝对路径。
  static Future<String> _resolveExecPath() async {
    // 优先尝试系统安装路径
    for (final candidate in ['/usr/bin/ztrans', '/usr/local/bin/ztrans']) {
      if (await File(candidate).exists()) return candidate;
    }
    // 回退到当前进程路径
    return Platform.resolvedExecutable;
  }

  /// 生成 autostart .desktop 文件内容
  static Future<String> _buildDesktopContent() async {
    final exec = await _resolveExecPath();
    return '''[Desktop Entry]
Type=Application
Name=ZTrans
Comment=Desktop translation application
Exec=$exec
Icon=ztrans
Terminal=false
StartupNotify=false
X-GNOME-Autostart-enabled=true
''';
  }

  // ── 读取开机启动状态（从文件系统） ────────────────────────────────────────

  static Future<bool> _readAutostartState() async {
    if (!Platform.isLinux) return false;
    final file = _autostartFile;
    if (!await file.exists()) return false;
    try {
      final content = await file.readAsString();
      // 若文件存在且未被禁用，则视为已启用
      if (content.contains('X-GNOME-Autostart-enabled=false')) return false;
      return true;
    } catch (_) {
      return false;
    }
  }

  // ── load ─────────────────────────────────────────────────────────────────

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final savedTheme = prefs.getString(_themeKey);
    if (savedTheme != null) {
      _themeMode = AppThemeMode.values.firstWhere(
        (e) => e.name == savedTheme,
        orElse: () => AppThemeMode.dark,
      );
    }
    final savedBackend = prefs.getString(_backendKey);
    if (savedBackend != null) {
      _backend = TranslatorBackend.values.firstWhere(
        (e) => e.name == savedBackend,
        orElse: () => TranslatorBackend.google,
      );
    }
    _openaiBaseUrl =
        prefs.getString(_openaiBaseUrlKey) ?? 'https://api.siliconflow.cn/v1';
    _openaiApiKey = prefs.getString(_openaiApiKeyKey) ?? '';
    _openaiModel = prefs.getString(_openaiModelKey) ?? 'Qwen/Qwen3-8B';
    _openaiThinking = prefs.getBool(_openaiThinkingKey) ?? false;
    _openaiSystemPrompt = prefs.getString(_openaiSystemPromptKey) ?? '';
    _ocrModel =
        prefs.getString(_ocrModelKey) ?? 'deepseek-ai/DeepSeek-OCR';
    _useXdgShortcuts = prefs.getBool(_useXdgShortcutsKey) ?? false;

    // 开机启动状态从文件系统读取，不存 SharedPreferences
    _autostart = await _readAutostartState();

    notifyListeners();
  }

  // ── setters ───────────────────────────────────────────────────────────────

  Future<void> setTheme(AppThemeMode mode) async {
    if (_themeMode == mode) return;
    _themeMode = mode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_themeKey, mode.name);
  }

  Future<void> setBackend(TranslatorBackend backend) async {
    if (_backend == backend) return;
    _backend = backend;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_backendKey, backend.name);
  }

  // 文本字段更新：更新字段但不触发 notifyListeners，避免 TextField 光标抖动
  Future<void> updateOpenaiBaseUrl(String url) async {
    _openaiBaseUrl = url;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_openaiBaseUrlKey, url);
  }

  Future<void> updateOpenaiApiKey(String key) async {
    _openaiApiKey = key;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_openaiApiKeyKey, key);
  }

  Future<void> updateOpenaiModel(String model) async {
    _openaiModel = model;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_openaiModelKey, model);
  }

  Future<void> updateOpenaiSystemPrompt(String prompt) async {
    _openaiSystemPrompt = prompt;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_openaiSystemPromptKey, prompt);
  }

  Future<void> setOpenaiThinking(bool enabled) async {
    if (_openaiThinking == enabled) return;
    _openaiThinking = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_openaiThinkingKey, enabled);
  }

  Future<void> updateOcrModel(String model) async {
    _ocrModel = model;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_ocrModelKey, model);
  }

  Future<void> setUseXdgShortcuts(bool enabled) async {
    if (_useXdgShortcuts == enabled) return;
    _useXdgShortcuts = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_useXdgShortcutsKey, enabled);
  }

  /// 设置开机自启动。
  ///
  /// - [enabled] = true：在 `~/.config/autostart/` 写入 ztrans.desktop
  /// - [enabled] = false：删除该文件
  ///
  /// 仅 Linux 平台生效，其他平台静默忽略。
  Future<void> setAutostart(bool enabled) async {
    if (!Platform.isLinux) return;
    if (_autostart == enabled) return;

    final file = _autostartFile;

    try {
      if (enabled) {
        // 确保目录存在
        await file.parent.create(recursive: true);
        final content = await _buildDesktopContent();
        await file.writeAsString(content);
      } else {
        if (await file.exists()) {
          await file.delete();
        }
      }
      _autostart = enabled;
      notifyListeners();
    } catch (e) {
      // 写入/删除失败时不更新状态，让 UI 保持原值
      debugPrint('[autostart] 操作失败: $e');
    }
  }
}
