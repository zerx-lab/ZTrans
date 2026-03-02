import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:rinf/rinf.dart';
import '../bindings/bindings.dart';
import '../widgets/title_bar.dart';

// 支持的语言列表
const _languages = [
  ('auto', '自动检测'),
  ('zh-CN', '中文（简体）'),
  ('zh-TW', '中文（繁体）'),
  ('en', 'English'),
  ('ja', '日本語'),
  ('ko', '한국어'),
  ('fr', 'Français'),
  ('de', 'Deutsch'),
  ('es', 'Español'),
  ('ru', 'Русский'),
  ('ar', 'العربية'),
  ('pt', 'Português'),
  ('it', 'Italiano'),
];

class HomePage extends StatefulWidget {
  const HomePage({super.key});

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
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _subscription = TranslateResponse.rustSignalStream.listen(_onResponse);
    _inputController.addListener(_onInputChanged);
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _debounce?.cancel();
    _inputController.dispose();
    _inputFocus.dispose();
    super.dispose();
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
    setState(() {
      _isLoading = true;
      _errorText = '';
    });
    TranslateRequest(
      text: text,
      sourceLang: _sourceLang == 'auto' ? 'auto' : _sourceLang,
      targetLang: _targetLang,
    ).sendSignalToRust();
  }

  void _onResponse(RustSignalPack<TranslateResponse> pack) {
    final msg = pack.message;
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

  void _swapLanguages() {
    if (_sourceLang == 'auto') return;
    setState(() {
      final tmp = _sourceLang;
      _sourceLang = _targetLang;
      _targetLang = tmp;
      // 互换文本
      final inputText = _inputController.text;
      _inputController.text = _translatedText;
      _translatedText = inputText;
    });
    if (_inputController.text.isNotEmpty) _translate();
  }

  void _clearInput() {
    _inputController.clear();
    setState(() {
      _translatedText = '';
      _errorText = '';
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: colors.surfaceContainerLowest,
      appBar: const AppTitleBar(),
      body: Column(
        children: [
          // 语言选择栏
          _LanguageBar(
            sourceLang: _sourceLang,
            targetLang: _targetLang,
            onSourceChanged: (lang) {
              setState(() => _sourceLang = lang);
              if (_inputController.text.isNotEmpty) _translate();
            },
            onTargetChanged: (lang) {
              setState(() => _targetLang = lang);
              if (_inputController.text.isNotEmpty) _translate();
            },
            onSwap: _swapLanguages,
          ),
          const Divider(height: 1),
          // 主翻译区域
          Expanded(
            child: Row(
              children: [
                // 左侧：输入面板
                Expanded(
                  child: _InputPanel(
                    controller: _inputController,
                    focusNode: _inputFocus,
                    onClear: _clearInput,
                    onTranslate: _translate,
                  ),
                ),
                // 分隔线
                Container(
                  width: 1,
                  color: colors.outlineVariant,
                ),
                // 右侧：结果面板
                Expanded(
                  child: _ResultPanel(
                    text: _translatedText,
                    error: _errorText,
                    isLoading: _isLoading,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── 语言选择栏 ───────────────────────────────────────────────────────────────

class _LanguageBar extends StatelessWidget {
  const _LanguageBar({
    required this.sourceLang,
    required this.targetLang,
    required this.onSourceChanged,
    required this.onTargetChanged,
    required this.onSwap,
  });

  final String sourceLang;
  final String targetLang;
  final ValueChanged<String> onSourceChanged;
  final ValueChanged<String> onTargetChanged;
  final VoidCallback onSwap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Container(
      height: 48,
      color: colors.surface,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          _LangSelector(
            value: sourceLang,
            items: _languages,
            onChanged: onSourceChanged,
          ),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.swap_horiz_rounded),
            tooltip: '互换语言',
            onPressed: sourceLang == 'auto' ? null : onSwap,
            color: colors.primary,
          ),
          const Spacer(),
          _LangSelector(
            value: targetLang,
            items: _languages.where((l) => l.$1 != 'auto').toList(),
            onChanged: onTargetChanged,
          ),
        ],
      ),
    );
  }
}

class _LangSelector extends StatelessWidget {
  const _LangSelector({
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
        style: TextStyle(
          fontSize: 13,
          color: colors.onSurface,
        ),
        icon: Icon(Icons.expand_more, size: 18, color: colors.onSurfaceVariant),
        borderRadius: BorderRadius.circular(8),
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

// ─── 输入面板 ─────────────────────────────────────────────────────────────────

class _InputPanel extends StatelessWidget {
  const _InputPanel({
    required this.controller,
    required this.focusNode,
    required this.onClear,
    required this.onTranslate,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onClear;
  final VoidCallback onTranslate;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Stack(
      children: [
        CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.enter, control: true):
                onTranslate,
          },
          child: TextField(
            controller: controller,
            focusNode: focusNode,
            maxLines: null,
            expands: true,
            autofocus: true,
            style: TextStyle(
              fontSize: 15,
              color: colors.onSurface,
              height: 1.6,
            ),
            decoration: InputDecoration(
              hintText: '输入要翻译的文字... (Ctrl+Enter 翻译)',
              hintStyle: TextStyle(
                color: colors.onSurfaceVariant.withValues(alpha: 0.5),
                fontSize: 14,
              ),
              border: InputBorder.none,
              contentPadding: const EdgeInsets.fromLTRB(20, 20, 56, 20),
            ),
          ),
        ),
        // 清除按钮
        Positioned(
          top: 8,
          right: 8,
          child: ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (context, value, child) {
              if (value.text.isEmpty) return const SizedBox.shrink();
              return IconButton(
                icon: const Icon(Icons.close, size: 18),
                tooltip: '清除',
                onPressed: onClear,
                color: colors.onSurfaceVariant,
              );
            },
          ),
        ),
      ],
    );
  }
}

// ─── 结果面板 ─────────────────────────────────────────────────────────────────

class _ResultPanel extends StatelessWidget {
  const _ResultPanel({
    required this.text,
    required this.error,
    required this.isLoading,
  });

  final String text;
  final String error;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Stack(
      children: [
        Container(
          color: colors.surfaceContainerLow,
          width: double.infinity,
          height: double.infinity,
          padding: const EdgeInsets.fromLTRB(20, 20, 56, 20),
          child: _buildContent(context, colors),
        ),
        // 复制按钮
        if (text.isNotEmpty)
          Positioned(
            top: 8,
            right: 8,
            child: _CopyButton(text: text),
          ),
        // 加载指示
        if (isLoading)
          Positioned(
            top: 14,
            right: 14,
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: colors.primary,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildContent(BuildContext context, ColorScheme colors) {
    if (error.isNotEmpty) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, size: 16, color: colors.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              error,
              style: TextStyle(color: colors.error, fontSize: 14),
            ),
          ),
        ],
      );
    }
    if (text.isEmpty && !isLoading) {
      return Text(
        '翻译结果将显示在此处',
        style: TextStyle(
          color: colors.onSurfaceVariant.withValues(alpha: 0.4),
          fontSize: 14,
        ),
      );
    }
    return SelectableText(
      text,
      style: TextStyle(
        fontSize: 15,
        color: colors.onSurface,
        height: 1.6,
      ),
    );
  }
}

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
        size: 18,
      ),
      tooltip: _copied ? '已复制' : '复制',
      onPressed: _copy,
      color: _copied ? colors.primary : colors.onSurfaceVariant,
    );
  }
}
