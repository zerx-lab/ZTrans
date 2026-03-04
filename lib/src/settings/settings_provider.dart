import 'package:flutter/foundation.dart';
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

  AppThemeMode _themeMode = AppThemeMode.dark;
  TranslatorBackend _backend = TranslatorBackend.google;
  String _openaiBaseUrl = 'https://api.siliconflow.cn/v1';
  String _openaiApiKey = '';
  String _openaiModel = 'Qwen/Qwen3-8B';
  bool _openaiThinking = false;
  String _openaiSystemPrompt = '';
  String _ocrModel = 'PaddlePaddle/PaddleOCR-VL';

  AppThemeMode get themeMode => _themeMode;
  TranslatorBackend get backend => _backend;
  String get openaiBaseUrl => _openaiBaseUrl;
  String get openaiApiKey => _openaiApiKey;
  String get openaiModel => _openaiModel;
  bool get openaiThinking => _openaiThinking;
  String get openaiSystemPrompt => _openaiSystemPrompt;
  String get ocrModel => _ocrModel;

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
        prefs.getString(_ocrModelKey) ?? 'PaddlePaddle/PaddleOCR-VL';
    notifyListeners();
  }

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
}
