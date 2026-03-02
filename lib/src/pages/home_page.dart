import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:rinf/rinf.dart';
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
  Timer? _debounce;
  int _counter = 0;
  String _lastRequestId = '';

  @override
  void initState() {
    super.initState();
    _subscription = TranslateResponse.rustSignalStream.listen(_onResponse);
    _inputController.addListener(_onInputChanged);
    _loadInitialText();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _debounce?.cancel();
    _inputController.dispose();
    _inputFocus.dispose();
    super.dispose();
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
    setState(() {
      _isLoading = true;
      _errorText = '';
    });
    TranslateRequest(
      text: text,
      sourceLang: _sourceLang,
      targetLang: _targetLang,
      requestId: _lastRequestId,
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
          SystemNavigator.pop();
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

class _SettingsDialog extends StatelessWidget {
  const _SettingsDialog({required this.settings});

  final SettingsProvider settings;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Dialog(
      backgroundColor: colors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: SizedBox(
        width: 220,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 16, bottom: 8),
                child: Text(
                  '外观主题',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: colors.onSurface,
                  ),
                ),
              ),
              ListenableBuilder(
                listenable: settings,
                builder: (context, _) => Column(
                  children: AppThemeMode.values
                      .map((mode) => _ThemeOption(mode: mode, settings: settings))
                      .toList(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

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
