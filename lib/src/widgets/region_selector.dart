import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 全屏截图选区界面。
/// 在已有截图的基础上让用户拖拽选择区域，选择完成后返回裁剪后的 PNG 字节。
class RegionSelector extends StatefulWidget {
  const RegionSelector({
    super.key,
    required this.pngBytes,
    required this.onSelected,
    required this.onCancelled,
  });

  final Uint8List pngBytes;
  final void Function(Uint8List croppedPng) onSelected;
  final VoidCallback onCancelled;

  @override
  State<RegionSelector> createState() => _RegionSelectorState();
}

class _RegionSelectorState extends State<RegionSelector> {
  ui.Image? _image;
  Offset? _start;
  Offset? _current;
  bool _processing = false;

  @override
  void initState() {
    super.initState();
    _decodeImage();
  }

  Future<void> _decodeImage() async {
    final codec = await ui.instantiateImageCodec(widget.pngBytes);
    final frame = await codec.getNextFrame();
    if (mounted) setState(() => _image = frame.image);
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  Rect? get _selectionRect {
    final s = _start;
    final c = _current;
    if (s == null || c == null) return null;
    return Rect.fromPoints(s, c);
  }

  Future<void> _confirmSelection() async {
    final rect = _selectionRect;
    final image = _image;
    if (rect == null || rect.width < 4 || rect.height < 4 || image == null) return;
    if (_processing) return;
    setState(() => _processing = true);

    try {
      // 将选区从逻辑像素转换到图像物理像素
      final size = context.size ?? const Size(1920, 1080);
      final scaleX = image.width / size.width;
      final scaleY = image.height / size.height;

      final src = Rect.fromLTWH(
        (rect.left * scaleX).clamp(0, image.width.toDouble()),
        (rect.top * scaleY).clamp(0, image.height.toDouble()),
        (rect.width * scaleX).clamp(0, image.width - rect.left * scaleX),
        (rect.height * scaleY).clamp(0, image.height - rect.top * scaleY),
      );

      if (src.width < 1 || src.height < 1) {
        setState(() => _processing = false);
        return;
      }

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawImageRect(
        image,
        src,
        Rect.fromLTWH(0, 0, src.width, src.height),
        Paint(),
      );
      final picture = recorder.endRecording();
      final cropped = await picture.toImage(src.width.toInt(), src.height.toInt());
      final byteData = await cropped.toByteData(format: ui.ImageByteFormat.png);
      cropped.dispose();

      if (byteData != null) {
        widget.onSelected(byteData.buffer.asUint8List());
      }
    } catch (_) {
      setState(() => _processing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): widget.onCancelled,
      },
      child: Focus(
        autofocus: true,
        child: MouseRegion(
          cursor: SystemMouseCursors.precise,
          child: GestureDetector(
            onPanStart: (d) {
              if (_processing) return;
              setState(() {
                _start = d.localPosition;
                _current = d.localPosition;
              });
            },
            onPanUpdate: (d) {
              if (_processing) return;
              setState(() => _current = d.localPosition);
            },
            onPanEnd: (_) {
              if (_processing) return;
              _confirmSelection();
            },
            child: Stack(
              fit: StackFit.expand,
              children: [
                // 背景：全屏截图
                if (_image != null)
                  RawImage(image: _image, fit: BoxFit.fill)
                else
                  const ColoredBox(color: Colors.black),

                // 半透明遮罩 + 选区镂空
                CustomPaint(
                  painter: _OverlayPainter(selectionRect: _selectionRect),
                ),

                // 加载中
                if (_image == null)
                  const Center(
                    child: CircularProgressIndicator(color: Colors.white),
                  ),

                // 处理中遮罩
                if (_processing)
                  const ColoredBox(
                    color: Color(0x55000000),
                    child: Center(
                      child: CircularProgressIndicator(color: Colors.white),
                    ),
                  ),

                // 提示文字（未开始拖拽时）
                if (_start == null && !_processing && _image != null)
                  const Align(
                    alignment: Alignment.topCenter,
                    child: Padding(
                      padding: EdgeInsets.only(top: 40),
                      child: _HintText('拖动鼠标选择截图区域   •   按 Esc 取消'),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _OverlayPainter extends CustomPainter {
  _OverlayPainter({required this.selectionRect});

  final Rect? selectionRect;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = selectionRect;
    const overlayColor = Color(0x77000000);

    if (rect == null || rect.width < 2 || rect.height < 2) {
      canvas.drawRect(Offset.zero & size, Paint()..color = overlayColor);
      return;
    }

    // 镂空遮罩：选区外暗化，选区内透明
    final outer = Path()..addRect(Offset.zero & size);
    final inner = Path()..addRect(rect);
    final cutout = Path.combine(PathOperation.difference, outer, inner);
    canvas.drawPath(cutout, Paint()..color = overlayColor);

    // 选区边框
    canvas.drawRect(
      rect,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );

    // 角点手柄
    const handleSize = 6.0;
    final corners = [
      rect.topLeft,
      rect.topRight,
      rect.bottomLeft,
      rect.bottomRight,
    ];
    for (final c in corners) {
      canvas.drawRect(
        Rect.fromCenter(center: c, width: handleSize, height: handleSize),
        Paint()..color = Colors.white,
      );
    }

    // 尺寸标注
    final label = '${rect.width.toInt()} × ${rect.height.toInt()}';
    final tp = TextPainter(
      text: TextSpan(
        text: label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          shadows: [Shadow(blurRadius: 3, color: Colors.black)],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final labelY = rect.top > 20 ? rect.top - 18 : rect.bottom + 4;
    tp.paint(canvas, Offset(rect.left, labelY));
  }

  @override
  bool shouldRepaint(_OverlayPainter old) => old.selectionRect != selectionRect;
}

class _HintText extends StatelessWidget {
  const _HintText(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: const TextStyle(color: Colors.white, fontSize: 14),
      ),
    );
  }
}
