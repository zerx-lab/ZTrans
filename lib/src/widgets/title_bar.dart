import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

class TitleBar extends StatefulWidget {
  const TitleBar({super.key, required this.onSettingsTap});

  final VoidCallback onSettingsTap;

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
            _TitleBarButton(
              icon: Icons.settings_outlined,
              tooltip: '设置',
              onTap: widget.onSettingsTap,
              color: colors.onSurfaceVariant,
            ),
            const SizedBox(width: 2),
            _TitleBarButton(
              icon: Icons.close,
              tooltip: '关闭',
              onTap: () => SystemNavigator.pop(),
              color: colors.onSurfaceVariant,
              hoverColor: colors.error,
            ),
          ],
        ),
      ),
    );
  }
}

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
