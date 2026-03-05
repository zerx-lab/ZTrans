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
  const HomePage({super.key, required this.settings});

  final SettingsProvider settings;

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

  StreamSubscription<RustSignalPack<TranslateResponse>>? _subscription;
  StreamSubscription<RustSignalPack<TranslateChunk>>? _chunkSubscription;
  StreamSubscription<RustSignalPack<ShortcutTriggered>>? _shortcutSubscription;
  StreamSubscription<RustSignalPack<ShortcutCaptureResult>>?
      _captureSubscription;
  Timer? _debounce;
  int _counter = 0;
  String _lastRequestId = '';
  String _lastCaptureRequestId = '';

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
    _inputController.dispose();
    _inputFocus.dispose();
    super.dispose();
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
      if (mounted) {
        setState(() {
          _isLoading = true;
          _translatedText = '';
          _errorText = '';
        });
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

    // 截图流程结束，恢复正常失焦隐藏逻辑，然后显示窗口
    appCapturing = false;
    windowManager.show().then((_) => windowManager.focus());

    // 用户取消选区时忽略错误，静默收尾
    if (msg.error == '截图已取消') {
      setState(() => _isLoading = false);
      return;
    }

    if (msg.error.isNotEmpty) {
      setState(() {
        _isLoading = false;
        _errorText = msg.error;
      });
      return;
    }

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
      setState(() {
        _translatedText = '';
        _errorText = '';
        _isLoading = false;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 600), _translate);
  }

  void _translate() {
    final text = _inputController.text.trim();
    if (text.isEmpty) return;
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
          windowManager.hide();
        },
      },
      child: Scaffold(
        backgroundColor: colors.surfaceContainerLowest,
        body: Column(
          children: [
            TitleBar(onSettingsTap: _showSettings),
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
              if (_inputController.text.isNotEmpty) _translate();
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
              if (_inputController.text.isNotEmpty) _translate();
            },
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 16,
            height: 16,
            child: _isLoading
                ? CircularProgressIndicator(
                    strokeWidth: 2,
                    color: colors.primary,
                  )
                : null,
          ),
        ],
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
                  if (_inputController.text.isNotEmpty) _translate();
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
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '使用 XDG portal 注册快捷键',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: colors.onSurface,
                                  ),
                                ),
                                Text(
                                  '启用后弹出系统快捷键配置界面\n禁用则通过系统设置自行绑定命令',
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: colors.onSurfaceVariant
                                        .withValues(alpha: 0.6),
                                    height: 1.4,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Switch(
                            value: widget.settings.useXdgShortcuts,
                            onChanged: widget.settings.setUseXdgShortcuts,
                          ),
                        ],
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
