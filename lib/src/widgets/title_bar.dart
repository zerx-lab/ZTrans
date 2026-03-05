import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

class TitleBar extends StatefulWidget {
  const TitleBar({
    super.key,
    required this.onSettingsTap,
    required this.pinned,
    required this.onPinChanged,
  });

  final VoidCallback onSettingsTap;
  final bool pinned;
  final ValueChanged<bool> onPinChanged;

  @override
  State<TitleBar> createState() => _TitleBarState();
}

class _TitleBarState extends State<TitleBar> {
  DateTime _lastTapTime = DateTime(0);
  static const _doubleTapTimeout = Duration(milliseconds: 300);

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) => windowManager.startDragging(),
      onTap: () {
        final now = DateTime.now();
        if (now.difference(_lastTapTime) < _doubleTapTimeout) {
          _lastTapTime = DateTime(0);
        } else {
          _lastTapTime = now;
        }
      },
      child: Container(
        height: 32,
        color: colors.surface,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(
          children: [
            Text(
              'ZTrans',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: colors.onSurface.withValues(alpha: 0.65),
                letterSpacing: 0.4,
              ),
            ),
            const Spacer(),
            // ── Pin 按钮 ──────────────────────────────────────────────────
            _PinButton(
              pinned: widget.pinned,
              onToggle: () => widget.onPinChanged(!widget.pinned),
              colors: colors,
            ),
            const SizedBox(width: 2),
            _TitleBarButton(
              icon: Icons.settings_outlined,
              tooltip: '设置',
              onTap: widget.onSettingsTap,
              color: colors.onSurfaceVariant,
            ),
            const SizedBox(width: 2),
            _TitleBarButton(
              icon: Icons.close,
              tooltip: '隐藏到托盘',
              onTap: () => windowManager.hide(),
              color: colors.onSurfaceVariant,
              hoverColor: colors.error,
            ),
          ],
        ),
      ),
    );
  }
}

// ── Pin 按钮 ──────────────────────────────────────────────────────────────────

class _PinButton extends StatefulWidget {
  const _PinButton({
    required this.pinned,
    required this.onToggle,
    required this.colors,
  });

  final bool pinned;
  final VoidCallback onToggle;
  final ColorScheme colors;

  @override
  State<_PinButton> createState() => _PinButtonState();
}

class _PinButtonState extends State<_PinButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final isPinned = widget.pinned;
    final activeColor = widget.colors.primary;
    final idleColor = widget.colors.onSurfaceVariant;

    // 钉住时：图标用主题色，背景淡色高亮
    // 悬浮时：淡色背景
    final iconColor = isPinned ? activeColor : idleColor;
    final bgColor = isPinned
        ? activeColor.withValues(alpha: _hovered ? 0.22 : 0.13)
        : _hovered
            ? idleColor.withValues(alpha: 0.15)
            : Colors.transparent;

    return Tooltip(
      message: isPinned ? '取消钉住（点击后失焦自动隐藏）' : '钉在桌面（失焦不隐藏）',
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onToggle,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 28,
            height: 22,
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Transform.rotate(
              // 未钉住时图标倾斜 45°，钉住时恢复竖直，给视觉反馈
              angle: isPinned ? 0 : 0.785398, // 0 or π/4
              child: Icon(
                Icons.push_pin_rounded,
                size: 14,
                color: iconColor,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── 通用标题栏按钮 ──────────────────────────────────────────────────────────

class _TitleBarButton extends StatefulWidget {
  const _TitleBarButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    required this.color,
    this.hoverColor,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final Color color;
  final Color? hoverColor;

  @override
  State<_TitleBarButton> createState() => _TitleBarButtonState();
}

class _TitleBarButtonState extends State<_TitleBarButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final effectiveColor =
        _hovered && widget.hoverColor != null ? widget.hoverColor! : widget.color;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Tooltip(
        message: widget.tooltip,
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            width: 28,
            height: 22,
            decoration: BoxDecoration(
              color: _hovered
                  ? effectiveColor.withValues(alpha: 0.15)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Icon(widget.icon, size: 14, color: effectiveColor),
          ),
        ),
      ),
    );
  }
}
