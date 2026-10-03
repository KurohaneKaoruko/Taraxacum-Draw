import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:taraxacum_draw/application/canvas_controller.dart';
import 'package:taraxacum_draw/application/view_transform.dart';
import 'package:taraxacum_draw/domain/stroke.dart';
import 'package:taraxacum_draw/infrastructure/render/layer_raster_cache.dart';
import 'package:taraxacum_draw/presentation/canvas/document_painter.dart';
import 'package:taraxacum_draw/presentation/canvas/layer_panel.dart';

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
          TextButton.icon(
            onPressed: () => showModalBottomSheet(
              context: context,
              builder: (_) => const LayerPanel(),
            ),
            icon: const Icon(Icons.layers),
            label: Text(_activeLayerName(ui)),
          ),
          IconButton(
            tooltip: '撤销',
            icon: const Icon(Icons.undo),
            onPressed: controller.undo,
          ),
          IconButton(
            tooltip: '重做',
            icon: const Icon(Icons.redo),
            onPressed: controller.redo,
          ),
          IconButton(
            tooltip: '清空画布',
            icon: const Icon(Icons.delete_sweep),
            onPressed: () => _confirmClear(context, controller),
          ),
        ],
      ),
      body: Column(
        children: [
          _ToolBar(ui: ui, controller: controller),
          const Divider(height: 1),
          Expanded(
            child: ClipRect(
              child: _CanvasInputArea(cache: cache),
            ),
          ),
        ],
      ),
    );
  }

  static String _activeLayerName(CanvasUiState ui) {
    for (final layer in ui.document.state.layers) {
      if (layer.id == ui.activeLayerId) return layer.name;
    }
    return '图层';
  }

  /// 清空前确认（drawing-canvas 规格要求）。
  Future<void> _confirmClear(
      BuildContext context, CanvasController controller) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清空画布'),
        content: const Text('将清除所有图层上的全部内容，可通过撤销恢复。确定继续？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed == true) controller.clearCanvas();
  }
}

/// 绘画输入区：单指/鼠标左键绘制，双指捏合缩放+平移，
/// 滚轮缩放，空格/中键拖拽平移。
class _CanvasInputArea extends ConsumerStatefulWidget {
  const _CanvasInputArea({required this.cache});

  final LayerRasterCache cache;

  @override
  ConsumerState<_CanvasInputArea> createState() => _CanvasInputAreaState();
}

class _CanvasInputAreaState extends ConsumerState<_CanvasInputArea> {
  final Map<int, Offset> _pointers = {};
  bool _navigating = false; // 双指手势进行中
  bool _panning = false; // 空格/中键拖拽
  Offset? _panLast;
  Offset? _pinchLastMid;
  double? _pinchLastDist;

  CanvasController get _controller =>
      ref.read(canvasProvider.notifier);

  ViewTransform get _view => ref.read(canvasProvider).view;

  bool get _spaceHeld => HardwareKeyboard.instance.isLogicalKeyPressed(
        LogicalKeyboardKey.space,
      );

  void _onDown(PointerDownEvent event) {
    _pointers[event.pointer] = event.localPosition;

    if (_pointers.length == 2) {
      // 第二根手指落下：进入双指导航，丢弃进行中笔画。
      _navigating = true;
      _controller.onPointerCancel();
      _pinchLastMid = _midOf(_pointers.values);
      _pinchLastDist = _distOf(_pointers.values);
      return;
    }
    if (_pointers.length > 2) return;

    if (_spaceHeld || event.buttons == kMiddleMouseButton) {
      _panning = true;
      _panLast = event.localPosition;
      return;
    }

    final canvasPos = _view.toCanvas(event.localPosition);
    _controller.onPointerDown(
      canvasPos.dx,
      canvasPos.dy,
      _naturalPressure(event.pressure),
    );
  }

  void _onMove(PointerMoveEvent event) {
    if (_pointers.containsKey(event.pointer)) {
      _pointers[event.pointer] = event.localPosition;
    }

    if (_navigating) {
      if (_pointers.length >= 2) {
        final mid = _midOf(_pointers.values);
        final dist = _distOf(_pointers.values);
        if (_pinchLastDist != null && _pinchLastDist! > 0 && _pinchLastMid != null) {
          var t = _view.zoomAt(mid, dist / _pinchLastDist!);
          t = t.panBy(mid - _pinchLastMid!);
          _controller.setView(t);
        }
        _pinchLastMid = mid;
        _pinchLastDist = dist;
      }
      return;
    }

    if (_panning) {
      _controller.setView(_view.panBy(event.localPosition - _panLast!));
      _panLast = event.localPosition;
      return;
    }

    // 绘制中：仅首个指针产生笔迹。
    final inProgress = ref.read(canvasProvider).inProgress;
    if (inProgress != null && _pointers.isNotEmpty) {
      final canvasPos = _view.toCanvas(event.localPosition);
      _controller.onPointerMove(
        canvasPos.dx,
        canvasPos.dy,
        _naturalPressure(event.pressure),
      );
    }
  }

  void _onUp(PointerEvent event) {
    _pointers.remove(event.pointer);
    if (_navigating) {
      if (_pointers.length < 2) {
        _navigating = false;
        _pinchLastMid = null;
        _pinchLastDist = null;
      }
      return;
    }
    if (_panning) {
      _panning = false;
      return;
    }
    if (event is PointerUpEvent) {
      _controller.onPointerUp();
    } else {
      _controller.onPointerCancel();
    }
  }

  void _onSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      final factor = math.exp(-event.scrollDelta.dy * 0.0015);
      _controller.setView(_view.zoomAt(event.localPosition, factor));
    }
  }

  static Offset _midOf(Iterable<Offset> points) {
    final list = points.toList();
    return Offset(
      list.fold(0.0, (s, p) => s + p.dx) / list.length,
      list.fold(0.0, (s, p) => s + p.dy) / list.length,
    );
  }

  static double _distOf(Iterable<Offset> points) {
    final list = points.toList();
    if (list.length < 2) return 0;
    return (list[0] - list[1]).distance;
  }

  /// 鼠标 pressure 恒为 0（或 1）无意义，仅手写笔上报真实压力。
  static double? _naturalPressure(double pressure) =>
      pressure > 0 && pressure < 1 ? pressure : null;

  @override
  Widget build(BuildContext context) {
    final ui = ref.watch(canvasProvider);
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _onDown,
      onPointerMove: _onMove,
      onPointerUp: _onUp,
      onPointerCancel: _onUp,
      onPointerSignal: _onSignal,
      child: CustomPaint(
        size: Size.infinite,
        painter: DocumentPainter(
          cache: widget.cache,
          state: ui.document.state,
          view: ui.view,
          activeStroke: _activeStrokeOf(ui),
        ),
      ),
    );
  }

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
              color:
                  selected ? Theme.of(context).colorScheme.primary : Colors.white,
              width: selected ? 3 : 1,
            ),
          ),
        ),
      ),
    );
  }
}
