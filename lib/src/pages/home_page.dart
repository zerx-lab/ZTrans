import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData, LogicalKeyboardKey;
import 'package:rinf/rinf.dart';
import 'package:window_manager/window_manager.dart';
import '../../main.dart' show appCapturing;
import '../bindings/bindings.dart';
import '../settings/settings_provider.dart';
import '../themes/app_themes.dart';
import '../widgets/title_bar.dart';

const _languages = [
  ('auto', '自动'),
  ('zh-CN', '中文'),
  ('en', 'English'),
  ('ja', '日本語'),
  ('ko', '한국어'),
  ('fr', 'Français'),
  ('de', 'Deutsch'),
  ('es', 'Español'),
  ('ru', 'Русский'),
];

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.settings,
    required this.onPinChanged,
  });

  final SettingsProvider settings;
  final ValueChanged<bool> onPinChanged;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _inputController = TextEditingController();
  final _inputFocus = FocusNode();
  String _translatedText = '';
  String _errorText = '';
  bool _isLoading = false;
  String _sourceLang = 'auto';
  String _targetLang = 'zh-CN';
  bool _pinned = false;

  /// OCR 当前阶段："capturing" | "ocr" | ""（非 OCR 时为空）
  String _captureStatus = '';
  /// OCR 计时器（每秒 tick，用于显示经过时间）
  Timer? _captureTimer;
  /// OCR 流程已经过秒数
  int _captureElapsed = 0;

  StreamSubscription<RustSignalPack<TranslateResponse>>? _subscription;
  StreamSubscription<RustSignalPack<TranslateChunk>>? _chunkSubscription;
  StreamSubscription<RustSignalPack<ShortcutTriggered>>? _shortcutSubscription;
  StreamSubscription<RustSignalPack<ShortcutCaptureResult>>?
      _captureSubscription;
  Timer? _debounce;
  int _counter = 0;
  String _lastRequestId = '';
  String _lastCaptureRequestId = '';

  /// 上一次实际发起翻译时的原文、源语言、目标语言，用于去重判断
  String _lastTranslatedText = '';
  String _lastTranslatedSourceLang = '';
  String _lastTranslatedTargetLang = '';

  @override
  void initState() {
    super.initState();
    _subscription = TranslateResponse.rustSignalStream.listen(_onResponse);
    _chunkSubscription = TranslateChunk.rustSignalStream.listen(_onChunk);
    _shortcutSubscription =
        ShortcutTriggered.rustSignalStream.listen(_onShortcutTriggered);
    _captureSubscription =
        ShortcutCaptureResult.rustSignalStream.listen(_onCaptureResult);
    _inputController.addListener(_onInputChanged);
    _loadInitialText();
    // 通知 Rust 所有 listener 已注册，同时传递快捷键配置
    AppReady(
      useXdgShortcuts: widget.settings.useXdgShortcuts,
    ).sendSignalToRust();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _chunkSubscription?.cancel();
    _shortcutSubscription?.cancel();
    _captureSubscription?.cancel();
    _debounce?.cancel();
    _captureTimer?.cancel();
    _inputController.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  /// 启动 OCR 计时器，每秒更新已经过时间
  void _startCaptureTimer() {
    _captureTimer?.cancel();
    _captureElapsed = 0;
    _captureTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _captureElapsed++);
    });
  }

  Future<void> _onShortcutTriggered(
      RustSignalPack<ShortcutTriggered> pack) async {
    final action = pack.message.action;

    if (action == 'translate-clipboard') {
      // Rust 端在窗口聚焦前已预先读取，直接使用，避免焦点转移后 primary selection 丢失
      final selectedText = pack.message.selectedText.trim();
      final clipboardText = pack.message.clipboardText.trim();
      await windowManager.show();
      await windowManager.focus();
      await _applyTranslateText(selectedText, clipboardText);
    } else if (action == 'capture-region-translate') {
      // 标记截图中，阻止 onWindowBlur 自动隐藏
      appCapturing = true;
      // 先隐藏窗口，避免出现在截图中
      await windowManager.hide();
      _lastCaptureRequestId = 'cap-${DateTime.now().millisecondsSinceEpoch}';
      // 清空去重缓存：OCR 识别结果可能与上次翻译文字相同，
      // 若不清空，_translate 会因去重命中而直接 return，导致 _isLoading 永久 true
      _lastTranslatedText = '';
      _lastTranslatedSourceLang = '';
      _lastTranslatedTargetLang = '';
      if (mounted) {
        setState(() {
          _isLoading = true;
          _captureStatus = 'capturing';
          _translatedText = '';
          _errorText = '';
        });
        _startCaptureTimer();
      }
      final s = widget.settings;
      // Rust 截全屏后会发回 ScreenCaptureReady，再显示选区界面
      CaptureAndTranslateRequest(
        requestId: _lastCaptureRequestId,
        ocrModel: s.ocrModel,
        ocrBaseUrl: s.openaiBaseUrl,
        ocrApiKey: s.openaiApiKey,
      ).sendSignalToRust();
    }
  }

  void _onCaptureResult(RustSignalPack<ShortcutCaptureResult> pack) {
    final msg = pack.message;
    if (msg.requestId != _lastCaptureRequestId) return;
    if (!mounted) return;

    // 中间进度信号（capturing / ocr）：仅更新阶段文字，不触发窗口恢复
    if (msg.status == 'capturing' || msg.status == 'ocr') {
      setState(() => _captureStatus = msg.status);
      return;
    }

    // 最终结果（done / error / 取消）：恢复正常失焦隐藏逻辑，然后显示窗口
    appCapturing = false;
    windowManager.show().then((_) => windowManager.focus());

    // 用户取消选区时忽略错误，静默收尾
    if (msg.error == '截图已取消') {
      _captureTimer?.cancel();
      _captureTimer = null;
      setState(() {
        _isLoading = false;
        _captureStatus = '';
        _captureElapsed = 0;
      });
      return;
    }

    if (msg.error.isNotEmpty) {
      _captureTimer?.cancel();
      _captureTimer = null;
      setState(() {
        _isLoading = false;
        _captureStatus = '';
        _captureElapsed = 0;
        _errorText = msg.error;
      });
      return;
    }

    // status == 'done'：停止计时，填入文字并触发翻译
    // 先将 _isLoading 置 false，防御性保证：即使 _translate 因任何原因提前 return，
    // loading 状态也不会永久卡住（例如 msg.text 为空、去重命中等边缘情况）
    setState(() {
      _isLoading = false;
      _captureStatus = '';
      _captureElapsed = 0;
    });
    _captureTimer?.cancel();
    _captureTimer = null;

    // 暂时移除 listener，避免 _onInputChanged 触发 debounce 与 _translate 竞争
    _inputController.removeListener(_onInputChanged);
    _inputController.value = TextEditingValue(
      text: msg.text,
      selection: TextSelection(baseOffset: 0, extentOffset: msg.text.length),
    );
    _inputController.addListener(_onInputChanged);

    // 直接触发翻译，不经过 debounce
    _translate();
  }

  Future<void> _loadInitialText() async {
    String text = '';
    try {
      final result =
          await Process.run('wl-paste', ['--primary', '--no-newline']);
      if (result.exitCode == 0) {
        text = (result.stdout as String).trim();
      }
    } catch (_) {}
    if (text.isEmpty) {
      try {
        final result = await Process.run('wl-paste', ['--no-newline']);
        if (result.exitCode == 0) {
          text = (result.stdout as String).trim();
        }
      } catch (_) {}
    }
    if (!mounted) return;
    if (text.isNotEmpty) {
      _inputController.value = TextEditingValue(
        text: text,
        selection: TextSelection(baseOffset: 0, extentOffset: text.length),
      );
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 300), _translate);
    }
    _inputFocus.requestFocus();
  }

  /// 快捷键触发时将文字填入输入框并翻译。
  /// 优先使用 [selectedText]（鼠标当前选中文字），若为空则回退到 [clipboardText]（剪贴板）。
  /// 两者均由 Rust 端在窗口聚焦前预先读取，避免焦点转移后 primary selection 被清空。
  Future<void> _applyTranslateText(
      String selectedText, String clipboardText) async {
    // 优先使用鼠标选中文字，无选中则回退到剪贴板
    final text = selectedText.isNotEmpty ? selectedText : clipboardText;
    if (!mounted) return;
    _inputFocus.requestFocus();
    if (text.isNotEmpty) {
      _inputController.removeListener(_onInputChanged);
      _inputController.value = TextEditingValue(
        text: text,
        selection: TextSelection(baseOffset: 0, extentOffset: text.length),
      );
      _inputController.addListener(_onInputChanged);
      _translate();
    }
  }

  void _onInputChanged() {
    _debounce?.cancel();
    if (_inputController.text.trim().isEmpty) {
      // 清空输入时同步重置去重缓存，确保重新输入相同内容时能正常触发翻译
      _lastTranslatedText = '';
      _lastTranslatedSourceLang = '';
      _lastTranslatedTargetLang = '';
      setState(() {
        _translatedText = '';
        _errorText = '';
        _isLoading = false;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 600), _translate);
  }

  void _translate({bool force = false}) {
    final text = _inputController.text.trim();
    if (text.isEmpty) return;

    // 内容、源语言、目标语言均未变化时跳过，避免重复翻译
    if (!force &&
        text == _lastTranslatedText &&
        _sourceLang == _lastTranslatedSourceLang &&
        _targetLang == _lastTranslatedTargetLang) {
      return;
    }

    _lastTranslatedText = text;
    _lastTranslatedSourceLang = _sourceLang;
    _lastTranslatedTargetLang = _targetLang;

    _counter++;
    _lastRequestId = '$_counter';
    final s = widget.settings;
    setState(() {
      _isLoading = true;
      _errorText = '';
      _translatedText = '';
    });
    TranslateRequest(
      text: text,
      sourceLang: _sourceLang,
      targetLang: _targetLang,
      requestId: _lastRequestId,
      backend: s.backend == TranslatorBackend.openai ? 'openai' : 'google',
      openaiBaseUrl: s.openaiBaseUrl,
      openaiApiKey: s.openaiApiKey,
      openaiModel: s.openaiModel,
      openaiThinking: s.openaiThinking,
      openaiSystemPrompt: s.openaiSystemPrompt,
    ).sendSignalToRust();
  }

  void _onResponse(RustSignalPack<TranslateResponse> pack) {
    final msg = pack.message;
    if (msg.requestId != _lastRequestId) return;
    if (!mounted) return;
    setState(() {
      _isLoading = false;
      if (msg.error.isNotEmpty) {
        _errorText = msg.error;
        _translatedText = '';
      } else {
        _translatedText = msg.translatedText;
        _errorText = '';
      }
    });
  }

  void _onChunk(RustSignalPack<TranslateChunk> pack) {
    final msg = pack.message;
    if (msg.requestId != _lastRequestId) return;
    if (!mounted) return;
    setState(() {
      if (msg.error.isNotEmpty) {
        _isLoading = false;
        _errorText = msg.error;
        _translatedText = '';
      } else if (msg.isDone) {
        _isLoading = false;
      } else {
        _translatedText += msg.chunkText;
      }
    });
  }

  void _clearInput() {
    _inputController.clear();
    // 清空时同步重置去重缓存，确保重新输入相同内容时能正常触发翻译
    _lastTranslatedText = '';
    _lastTranslatedSourceLang = '';
    _lastTranslatedTargetLang = '';
    setState(() {
      _translatedText = '';
      _errorText = '';
    });
    _inputFocus.requestFocus();
  }

  void _showSettings() {
    showDialog(
      context: context,
      builder: (ctx) => _SettingsDialog(settings: widget.settings),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (!_pinned) windowManager.hide();
        },
      },
      child: Scaffold(
        backgroundColor: colors.surfaceContainerLowest,
        body: Column(
          children: [
            TitleBar(
              onSettingsTap: _showSettings,
              pinned: _pinned,
              onPinChanged: (pinned) {
                setState(() => _pinned = pinned);
                widget.onPinChanged(pinned);
              },
            ),
            Container(height: 1, color: colors.outlineVariant),
            _buildLanguageBar(colors),
            Container(height: 1, color: colors.outlineVariant),
            Expanded(child: _buildInputArea(colors)),
            Container(height: 1, color: colors.outlineVariant),
            Expanded(child: _buildResultArea(colors)),
            Container(height: 1, color: colors.outlineVariant),
            _buildStatusBar(colors),
          ],
        ),
      ),
    );
  }

  Widget _buildLanguageBar(ColorScheme colors) {
    return Container(
      height: 40,
      color: colors.surface,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          _LangDropdown(
            value: _sourceLang,
            items: _languages,
            onChanged: (lang) {
                setState(() => _sourceLang = lang);
                if (_inputController.text.isNotEmpty) _translate(force: true);
              },
          ),
          const Spacer(),
          Icon(Icons.arrow_forward, size: 16, color: colors.onSurfaceVariant),
          const Spacer(),
          _LangDropdown(
            value: _targetLang,
            items: _languages.where((l) => l.$1 != 'auto').toList(),
            onChanged: (lang) {
                setState(() => _targetLang = lang);
                if (_inputController.text.isNotEmpty) _translate(force: true);
              },
          ),
          const SizedBox(width: 8),
          if (_isLoading) _buildLoadingIndicator(colors),
        ],
      ),
    );
  }

  /// 构建加载指示器：OCR 阶段显示阶段文字+计时，普通翻译只显示转圈
  Widget _buildLoadingIndicator(ColorScheme colors) {
    if (_captureStatus == 'capturing' || _captureStatus == 'ocr') {
      final label = _captureStatus == 'capturing' ? '截图中' : '识别中';
      final elapsed = _captureElapsed > 0 ? ' ${_captureElapsed}s' : '';
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: colors.primary,
            ),
          ),
          const SizedBox(width: 5),
          Text(
            '$label$elapsed',
            style: TextStyle(
              fontSize: 11,
              color: colors.primary,
            ),
          ),
        ],
      );
    }
    // 普通翻译：仅显示转圈
    return SizedBox(
      width: 16,
      height: 16,
      child: CircularProgressIndicator(
        strokeWidth: 2,
        color: colors.primary,
      ),
    );
  }

  Widget _buildInputArea(ColorScheme colors) {
    return Stack(
      children: [
        CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.enter, control: true):
                _translate,
          },
          child: TextField(
            controller: _inputController,
            focusNode: _inputFocus,
            autofocus: true,
            maxLines: null,
            expands: true,
            style: TextStyle(
              fontSize: 14,
              color: colors.onSurface,
              height: 1.5,
            ),
            decoration: InputDecoration(
              hintText: '输入要翻译的文字...',
              hintStyle: TextStyle(
                color: colors.onSurfaceVariant.withValues(alpha: 0.5),
                fontSize: 13,
              ),
              border: InputBorder.none,
              contentPadding: const EdgeInsets.fromLTRB(14, 12, 40, 12),
            ),
          ),
        ),
        Positioned(
          top: 4,
          right: 4,
          child: ValueListenableBuilder<TextEditingValue>(
            valueListenable: _inputController,
            builder: (context, value, child) {
              if (value.text.isEmpty) return const SizedBox.shrink();
              return IconButton(
                icon: const Icon(Icons.close, size: 16),
                tooltip: '清除',
                onPressed: _clearInput,
                color: colors.onSurfaceVariant,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(
                  minWidth: 28,
                  minHeight: 28,
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildStatusBar(ColorScheme colors) {
    return ListenableBuilder(
      listenable: widget.settings,
      builder: (context, _) {
        final isGoogle =
            widget.settings.backend == TranslatorBackend.google;
        return Container(
          height: 26,
          color: colors.surfaceContainer,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            children: [
              const Spacer(),
              _BackendSegment(
                isGoogle: isGoogle,
                onSelect: (backend) {
                  widget.settings.setBackend(backend);
                  if (_inputController.text.isNotEmpty) _translate(force: true);
                },
                colors: colors,
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildResultArea(ColorScheme colors) {
    return Stack(
      children: [
        Container(
          color: colors.surfaceContainerLow,
          width: double.infinity,
          height: double.infinity,
          padding: const EdgeInsets.fromLTRB(14, 12, 40, 12),
          child: _buildResultContent(colors),
        ),
        if (_translatedText.isNotEmpty)
          Positioned(
            top: 4,
            right: 4,
            child: _CopyButton(text: _translatedText),
          ),
      ],
    );
  }

  Widget _buildResultContent(ColorScheme colors) {
    if (_errorText.isNotEmpty) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, size: 14, color: colors.error),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              _errorText,
              style: TextStyle(color: colors.error, fontSize: 13),
            ),
          ),
        ],
      );
    }
    // OCR 进行中：显示阶段提示，覆盖默认占位文字
    if (_isLoading && _captureStatus.isNotEmpty && _translatedText.isEmpty) {
      final (IconData icon, String label) = switch (_captureStatus) {
        'capturing' => (Icons.crop_free, '请框选要识别的区域…'),
        'ocr' => (Icons.document_scanner_outlined, 'OCR 识别中，请稍候…'),
        _ => (Icons.hourglass_empty, '处理中…'),
      };
      final elapsed = _captureElapsed > 0 ? '（已等待 ${_captureElapsed}s）' : '';
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 15, color: colors.primary),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(color: colors.primary, fontSize: 13),
              ),
            ],
          ),
          if (elapsed.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              elapsed,
              style: TextStyle(
                color: colors.onSurfaceVariant.withValues(alpha: 0.5),
                fontSize: 11,
              ),
            ),
          ],
          // OCR 阶段超过 10 秒时给出提示，缓解用户焦虑
          if (_captureStatus == 'ocr' && _captureElapsed >= 10) ...[
            const SizedBox(height: 4),
            Text(
              '正在等待 API 响应，网络较慢时可能需要更长时间',
              style: TextStyle(
                color: colors.onSurfaceVariant.withValues(alpha: 0.45),
                fontSize: 11,
              ),
            ),
          ],
        ],
      );
    }

    if (_translatedText.isEmpty) {
      return Text(
        '翻译结果将显示在此处',
        style: TextStyle(
          color: colors.onSurfaceVariant.withValues(alpha: 0.4),
          fontSize: 13,
        ),
      );
    }
    return SelectableText(
      _translatedText,
      style: TextStyle(
        fontSize: 14,
        color: colors.onSurface,
        height: 1.5,
      ),
    );
  }
}

// ── 设置对话框 ──────────────────────────────────────────────────────────────

class _SettingsDialog extends StatefulWidget {
  const _SettingsDialog({required this.settings});

  final SettingsProvider settings;

  @override
  State<_SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<_SettingsDialog> {
  late final TextEditingController _baseUrlCtrl;
  late final TextEditingController _apiKeyCtrl;
  late final TextEditingController _modelCtrl;
  late final TextEditingController _systemPromptCtrl;
  late final TextEditingController _ocrModelCtrl;

  @override
  void initState() {
    super.initState();
    _baseUrlCtrl = TextEditingController(text: widget.settings.openaiBaseUrl);
    _apiKeyCtrl = TextEditingController(text: widget.settings.openaiApiKey);
    _modelCtrl = TextEditingController(text: widget.settings.openaiModel);
    _systemPromptCtrl =
        TextEditingController(text: widget.settings.openaiSystemPrompt);
    _ocrModelCtrl = TextEditingController(text: widget.settings.ocrModel);
  }

  @override
  void dispose() {
    _baseUrlCtrl.dispose();
    _apiKeyCtrl.dispose();
    _modelCtrl.dispose();
    _systemPromptCtrl.dispose();
    _ocrModelCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Dialog(
      backgroundColor: colors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: SizedBox(
        width: 340,
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: ListenableBuilder(
            listenable: widget.settings,
            builder: (context, _) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _sectionLabel(colors, '外观主题'),
                ...AppThemeMode.values.map(
                  (mode) =>
                      _ThemeOption(mode: mode, settings: widget.settings),
                ),
                Divider(
                  height: 24,
                  indent: 16,
                  endIndent: 16,
                  color: colors.outlineVariant,
                ),
                _sectionLabel(colors, '翻译后端'),
                _BackendOption(
                  backend: TranslatorBackend.google,
                  label: 'Google 翻译',
                  settings: widget.settings,
                ),
                _BackendOption(
                  backend: TranslatorBackend.openai,
                  label: 'OpenAI 兼容',
                  settings: widget.settings,
                ),
                if (widget.settings.backend == TranslatorBackend.openai)
                  _OpenAISettings(
                    settings: widget.settings,
                    baseUrlCtrl: _baseUrlCtrl,
                    apiKeyCtrl: _apiKeyCtrl,
                    modelCtrl: _modelCtrl,
                    systemPromptCtrl: _systemPromptCtrl,
                  ),
                Divider(
                  height: 24,
                  indent: 16,
                  endIndent: 16,
                  color: colors.outlineVariant,
                ),
                if (Platform.isLinux) ...[
                  _sectionLabel(colors, '开机启动'),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '登录后自动启动 ZTrans',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: colors.onSurface,
                                ),
                              ),
                              Text(
                                '写入 ~/.config/autostart/ztrans.desktop',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: colors.onSurfaceVariant
                                      .withValues(alpha: 0.6),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Switch(
                          value: widget.settings.autostart,
                          onChanged: widget.settings.setAutostart,
                        ),
                      ],
                    ),
                  ),
                  Divider(
                    height: 24,
                    indent: 16,
                    endIndent: 16,
                    color: colors.outlineVariant,
                  ),
                ],
                _sectionLabel(colors, '截图 OCR'),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'OCR 模型（使用上方同一 Base URL / API Key）',
                        style: TextStyle(
                          fontSize: 11,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 4),
                      _SettingField(
                        label: '模型名称',
                        controller: _ocrModelCtrl,
                        onChanged: widget.settings.updateOcrModel,
                      ),
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: colors.surfaceContainerLow,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: colors.outlineVariant),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  Icons.keyboard_rounded,
                                  size: 13,
                                  color: colors.primary,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  '如何设置全局快捷键',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: colors.onSurface,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            _ShortcutTip(
                              colors: colors,
                              label: 'GNOME',
                              description: '系统设置 → 键盘 → 键盘快捷键 → 自定义快捷键，添加命令：',
                              command: 'ztrans --translate-clipboard',
                            ),
                            const SizedBox(height: 6),
                            _ShortcutTip(
                              colors: colors,
                              label: 'KDE',
                              description: '系统设置 → 快捷键 → 自定义快捷键，新建"命令/URL"，命令填：',
                              command: 'ztrans --translate-clipboard',
                            ),
                            const SizedBox(height: 6),
                            _ShortcutTip(
                              colors: colors,
                              label: '截图 OCR',
                              description: '同上，截图识别命令：',
                              command: 'ztrans --capture-translate',
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _sectionLabel(ColorScheme colors, String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 16, bottom: 8),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: colors.onSurface,
        ),
      ),
    );
  }
}

class _BackendOption extends StatelessWidget {
  const _BackendOption({
    required this.backend,
    required this.label,
    required this.settings,
  });

  final TranslatorBackend backend;
  final String label;
  final SettingsProvider settings;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isSelected = settings.backend == backend;
    return InkWell(
      onTap: () => settings.setBackend(backend),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Icon(
              isSelected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 18,
              color: isSelected ? colors.primary : colors.onSurfaceVariant,
            ),
            const SizedBox(width: 12),
            Text(label, style: TextStyle(fontSize: 13, color: colors.onSurface)),
          ],
        ),
      ),
    );
  }
}

class _OpenAISettings extends StatelessWidget {
  const _OpenAISettings({
    required this.settings,
    required this.baseUrlCtrl,
    required this.apiKeyCtrl,
    required this.modelCtrl,
    required this.systemPromptCtrl,
  });

  final SettingsProvider settings;
  final TextEditingController baseUrlCtrl;
  final TextEditingController apiKeyCtrl;
  final TextEditingController modelCtrl;
  final TextEditingController systemPromptCtrl;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SettingField(
            label: 'Base URL',
            controller: baseUrlCtrl,
            onChanged: settings.updateOpenaiBaseUrl,
          ),
          const SizedBox(height: 10),
          _SettingField(
            label: 'API Key',
            controller: apiKeyCtrl,
            obscure: true,
            onChanged: settings.updateOpenaiApiKey,
          ),
          const SizedBox(height: 10),
          _SettingField(
            label: '模型名称',
            controller: modelCtrl,
            onChanged: settings.updateOpenaiModel,
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Text(
                '思考模式',
                style: TextStyle(fontSize: 12, color: colors.onSurface),
              ),
              const Spacer(),
              Switch(
                value: settings.openaiThinking,
                onChanged: settings.setOpenaiThinking,
              ),
            ],
          ),
          const SizedBox(height: 10),
          _SystemPromptField(
            controller: systemPromptCtrl,
            onChanged: settings.updateOpenaiSystemPrompt,
          ),
        ],
      ),
    );
  }
}

class _SettingField extends StatelessWidget {
  const _SettingField({
    required this.label,
    required this.controller,
    required this.onChanged,
    this.obscure = false,
  });

  final String label;
  final TextEditingController controller;
  final bool obscure;
  final void Function(String) onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: 4),
        TextField(
          controller: controller,
          obscureText: obscure,
          onChanged: onChanged,
          style: TextStyle(fontSize: 12, color: colors.onSurface),
          decoration: InputDecoration(
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
              borderSide: BorderSide(color: colors.outlineVariant),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
              borderSide: BorderSide(color: colors.outlineVariant),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
              borderSide: BorderSide(color: colors.primary),
            ),
          ),
        ),
      ],
    );
  }
}

class _SystemPromptField extends StatelessWidget {
  const _SystemPromptField({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final void Function(String) onChanged;

  static const _placeholder =
      '留空则使用默认提示词：\n你是专业翻译助手。请将给定文本准确、自然地翻译成目标语言。只输出翻译结果，不附加解释或说明。';

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '系统提示词',
              style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
            ),
            const Spacer(),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: controller,
              builder: (context, value, _) {
                if (value.text.isEmpty) return const SizedBox.shrink();
                return GestureDetector(
                  onTap: () {
                    controller.clear();
                    onChanged('');
                  },
                  child: Text(
                    '恢复默认',
                    style: TextStyle(fontSize: 11, color: colors.primary),
                  ),
                );
              },
            ),
          ],
        ),
        const SizedBox(height: 4),
        TextField(
          controller: controller,
          onChanged: onChanged,
          maxLines: 5,
          minLines: 3,
          style: TextStyle(fontSize: 12, color: colors.onSurface, height: 1.5),
          decoration: InputDecoration(
            hintText: _placeholder,
            hintStyle: TextStyle(
              fontSize: 11,
              color: colors.onSurfaceVariant.withValues(alpha: 0.5),
              height: 1.5,
            ),
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
              borderSide: BorderSide(color: colors.outlineVariant),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
              borderSide: BorderSide(color: colors.outlineVariant),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
              borderSide: BorderSide(color: colors.primary),
            ),
          ),
        ),
      ],
    );
  }
}

// ── 主题选项 ──────────────────────────────────────────────────────────────

class _ThemeOption extends StatelessWidget {
  const _ThemeOption({required this.mode, required this.settings});

  final AppThemeMode mode;
  final SettingsProvider settings;

  String get _label {
    switch (mode) {
      case AppThemeMode.light:
        return '浅色 (Light)';
      case AppThemeMode.dark:
        return '深色 (Dark)';
      case AppThemeMode.oneDarkPro:
        return 'One Dark Pro';
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isSelected = settings.themeMode == mode;
    return InkWell(
      onTap: () => settings.setTheme(mode),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Icon(
              isSelected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 18,
              color: isSelected ? colors.primary : colors.onSurfaceVariant,
            ),
            const SizedBox(width: 12),
            Text(
              _label,
              style: TextStyle(fontSize: 13, color: colors.onSurface),
            ),
          ],
        ),
      ),
    );
  }
}

// ── 后端分段控件 ────────────────────────────────────────────────────────────

// ── 后端分段控件 ────────────────────────────────────────────────────────────

class _BackendSegment extends StatelessWidget {
  const _BackendSegment({
    required this.isGoogle,
    required this.onSelect,
    required this.colors,
  });

  final bool isGoogle;
  final void Function(TranslatorBackend) onSelect;
  final ColorScheme colors;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 18,
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(5),
      ),
      padding: const EdgeInsets.all(2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Seg(
            icon: Icons.translate_rounded,
            tooltip: 'Google 翻译',
            selected: isGoogle,
            onTap: () => onSelect(TranslatorBackend.google),
            colors: colors,
          ),
          _Seg(
            icon: Icons.auto_awesome_rounded,
            tooltip: 'OpenAI 兼容',
            selected: !isGoogle,
            onTap: () => onSelect(TranslatorBackend.openai),
            colors: colors,
          ),
        ],
      ),
    );
  }
}

class _Seg extends StatelessWidget {
  const _Seg({
    required this.icon,
    required this.tooltip,
    required this.selected,
    required this.onTap,
    required this.colors,
  });

  final IconData icon;
  final String tooltip;
  final bool selected;
  final VoidCallback onTap;
  final ColorScheme colors;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 22,
          decoration: BoxDecoration(
            color: selected ? colors.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(3),
          ),
          alignment: Alignment.center,
          child: Icon(
            icon,
            size: 11,
            color: selected
                ? colors.onPrimary
                : colors.onSurfaceVariant.withValues(alpha: 0.6),
          ),
        ),
      ),
    );
  }
}

// ── 语言下拉框 ─────────────────────────────────────────────────────────────

class _LangDropdown extends StatelessWidget {
  const _LangDropdown({
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final String value;
  final List<(String, String)> items;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DropdownButtonHideUnderline(
      child: DropdownButton<String>(
        value: value,
        style: TextStyle(fontSize: 12, color: colors.onSurface),
        icon: Icon(Icons.expand_more, size: 16, color: colors.onSurfaceVariant),
        borderRadius: BorderRadius.circular(6),
        items: items
            .map((lang) => DropdownMenuItem(
                  value: lang.$1,
                  child: Text(lang.$2),
                ))
            .toList(),
        onChanged: (v) {
          if (v != null) onChanged(v);
        },
      ),
    );
  }
}

// ── 快捷键说明条目 ────────────────────────────────────────────────────────

class _ShortcutTip extends StatelessWidget {
  const _ShortcutTip({
    required this.colors,
    required this.label,
    required this.description,
    required this.command,
  });

  final ColorScheme colors;
  final String label;
  final String description;
  final String command;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: colors.primaryContainer,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: colors.onPrimaryContainer,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                description,
                style: TextStyle(
                  fontSize: 10,
                  color: colors.onSurfaceVariant,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 3),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
          decoration: BoxDecoration(
            color: colors.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            command,
            style: TextStyle(
              fontSize: 11,
              fontFamily: 'monospace',
              color: colors.onSurface,
              letterSpacing: 0.3,
            ),
          ),
        ),
      ],
    );
  }
}

// ── 复制按钮 ──────────────────────────────────────────────────────────────

class _CopyButton extends StatefulWidget {
  const _CopyButton({required this.text});
  final String text;

  @override
  State<_CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<_CopyButton> {
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.text));
    setState(() => _copied = true);
    await Future.delayed(const Duration(seconds: 2));
    if (mounted) setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return IconButton(
      icon: Icon(
        _copied ? Icons.check : Icons.copy_rounded,
        size: 16,
      ),
      tooltip: _copied ? '已复制' : '复制',
      onPressed: _copy,
      color: _copied ? colors.primary : colors.onSurfaceVariant,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
    );
  }
}
