import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:taraxacum_draw/application/canvas_controller.dart';
import 'package:taraxacum_draw/domain/stroke.dart';
import 'package:taraxacum_draw/infrastructure/render/layer_raster_cache.dart';
import 'package:taraxacum_draw/presentation/canvas/document_painter.dart';

/// 预设笔色（完整取色器留到后续任务）。
const _presetColors = <int>[
  0xFF1A1A1A,
  0xFFE53935,
  0xFF1E88E5,
  0xFF43A047,
  0xFFFB8C00,
  0xFF8E24AA,
];

/// 画布页面：工具栏 + 绘画区域。
///
/// 视图变换（缩放/平移）在 task 2.5 接入；当前指针坐标即画布逻辑坐标。
class CanvasPage extends ConsumerWidget {
  const CanvasPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ui = ref.watch(canvasProvider);
    final controller = ref.read(canvasProvider.notifier);
    final cache = ref.watch(_cacheProvider);

    return Scaffold(
      key: const Key('canvas_page'),
      appBar: AppBar(
        title: const Text('TaraxacumDraw'),
        actions: [
          IconButton(
            tooltip: '撤销',
            icon: const Icon(Icons.undo),
            onPressed: controller.undo, // task 2.3 实现
          ),
        ],
      ),
      body: Column(
        children: [
          _ToolBar(ui: ui, controller: controller),
          const Divider(height: 1),
          Expanded(
            child: ClipRect(
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: (event) => controller.onPointerDown(
                  event.localPosition.dx,
                  event.localPosition.dy,
                  _naturalPressure(event.pressure),
                ),
                onPointerMove: (event) => controller.onPointerMove(
                  event.localPosition.dx,
                  event.localPosition.dy,
                  _naturalPressure(event.pressure),
                ),
                onPointerUp: (_) => controller.onPointerUp(),
                onPointerCancel: (_) => controller.onPointerCancel(),
                child: CustomPaint(
                  size: Size.infinite,
                  painter: DocumentPainter(
                    cache: cache,
                    state: ui.document.state,
                    activeStroke: _activeStrokeOf(ui),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 鼠标 pressure 恒为 0（或 1）无意义，仅手写笔上报真实压力。
  static double? _naturalPressure(double pressure) =>
      pressure > 0 && pressure < 1 ? pressure : null;

  static Stroke? _activeStrokeOf(CanvasUiState ui) {
    final points = ui.inProgress;
    if (points == null || points.isEmpty) return null;
    return Stroke(
      id: 'in-progress',
      authorId: 'local',
      layerId: ui.activeLayerId,
      tool: ui.tool,
      color: ui.color,
      width: ui.width,
      points: points,
      createdAtMs: 0,
    );
  }
}

/// 缓存实例与界面同生命周期。
final _cacheProvider = Provider<LayerRasterCache>((ref) => LayerRasterCache());

class _ToolBar extends StatelessWidget {
  const _ToolBar({required this.ui, required this.controller});

  final CanvasUiState ui;
  final CanvasController controller;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          IconButton(
            tooltip: '画笔',
            isSelected: ui.tool == DrawTool.brush,
            icon: const Icon(Icons.brush),
            onPressed: () => controller.setTool(DrawTool.brush),
          ),
          IconButton(
            tooltip: '橡皮',
            isSelected: ui.tool == DrawTool.eraser,
            icon: const Icon(Icons.cleaning_services),
            onPressed: () => controller.setTool(DrawTool.eraser),
          ),
          const SizedBox(width: 8),
          for (final color in _presetColors)
            _ColorDot(
              color: color,
              selected: ui.color == color,
              onTap: () => controller.setColor(color),
            ),
          const SizedBox(width: 12),
          Expanded(
            child: Slider(
              min: 1,
              max: 40,
              value: ui.width,
              label: ui.width.toStringAsFixed(0),
              divisions: 39,
              onChanged: controller.setWidth,
            ),
          ),
        ],
      ),
    );
  }
}

class _ColorDot extends StatelessWidget {
  const _ColorDot({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final int color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: Color(color),
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? Theme.of(context).colorScheme.primary : Colors.white,
              width: selected ? 3 : 1,
            ),
          ),
        ),
      ),
    );
  }
}
