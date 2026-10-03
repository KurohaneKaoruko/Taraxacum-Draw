import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import 'package:taraxacum_draw/domain/canvas_document.dart';
import 'package:taraxacum_draw/domain/ids.dart';
import 'package:taraxacum_draw/domain/lamport_clock.dart';
import 'package:taraxacum_draw/domain/layer.dart';
import 'package:taraxacum_draw/domain/op.dart';
import 'package:taraxacum_draw/domain/stroke.dart';

/// 画布界面状态：文档 + 进行中笔画 + 当前工具设置。
class CanvasUiState {
  const CanvasUiState({
    required this.document,
    required this.tool,
    required this.color,
    required this.width,
    required this.activeLayerId,
    this.inProgress,
  });

  final CanvasDocument document;
  final DrawTool tool;
  final int color;
  final double width;
  final LayerId activeLayerId;

  /// 正在绘制中的笔画（未定稿，不进入文档）。
  final List<StrokePoint>? inProgress;

  CanvasUiState copyWith({
    DrawTool? tool,
    int? color,
    double? width,
    LayerId? activeLayerId,
    List<StrokePoint>? inProgress,
    bool clearInProgress = false,
  }) =>
      CanvasUiState(
        document: document,
        tool: tool ?? this.tool,
        color: color ?? this.color,
        width: width ?? this.width,
        activeLayerId: activeLayerId ?? this.activeLayerId,
        inProgress: clearInProgress ? null : (inProgress ?? this.inProgress),
      );
}

/// 画布控制器：指针事件 → 笔画 → AddStrokeOp 入文档。
///
/// 本阶段（task 2.1）为单机模式：clock/opId 本地生成；
/// 进入实时同步（task 5.x）后由同步层接管广播，此处接口不变。
class CanvasController extends Notifier<CanvasUiState> {
  static const _uuid = Uuid();
  final LamportClock _clock = LamportClock();

  @override
  CanvasUiState build() => CanvasUiState(
        document: CanvasDocument(),
        tool: DrawTool.brush,
        color: 0xFF1A1A1A,
        width: 4,
        activeLayerId: 'base',
      );

  void setTool(DrawTool tool) => state = state.copyWith(tool: tool);
  void setColor(int color) => state = state.copyWith(color: color);
  void setWidth(double width) => state = state.copyWith(width: width);
  void setActiveLayer(LayerId layerId) =>
      state = state.copyWith(activeLayerId: layerId);

  // ===== 图层操作（全部以 op 入账，可撤销）=====

  /// 新建图层并设为当前层。
  void addLayer() {
    final layers = state.document.state.layers;
    final maxOrder =
        layers.map((l) => l.order).reduce((a, b) => math.max(a, b));
    final layer = Layer(
      id: _uuid.v4(),
      name: '图层 ${layers.length + 1}',
      order: maxOrder + 1,
    );
    _apply((opId, lamport, wall) => AddLayerOp(
          opId: opId,
          authorId: 'local',
          lamport: lamport,
          wallTimeMs: wall,
          layer: layer,
        ));
    state = state.copyWith(activeLayerId: layer.id);
  }

  /// 删除图层；至少保留一个图层。其上的笔迹随重放一并消失。
  void removeLayer(LayerId layerId) {
    final layers = state.document.state.layers;
    if (layers.length <= 1) return;
    _apply((opId, lamport, wall) => RemoveLayerOp(
          opId: opId,
          authorId: 'local',
          lamport: lamport,
          wallTimeMs: wall,
          layerId: layerId,
        ));
    if (state.activeLayerId == layerId) {
      // 回退到存活的顶层。
      final next = layers.where((l) => l.id != layerId).last;
      state = state.copyWith(activeLayerId: next.id);
    }
  }

  /// 切换图层可见性。
  void toggleLayerVisible(LayerId layerId) {
    final layer =
        state.document.state.layers.firstWhere((l) => l.id == layerId);
    _apply((opId, lamport, wall) => SetLayerVisibleOp(
          opId: opId,
          authorId: 'local',
          lamport: lamport,
          wallTimeMs: wall,
          layerId: layerId,
          visible: !layer.visible,
        ));
  }

  /// 上移/下移一层（towardTop = true 表示朝顶层方向）。
  ///
  /// 交换相邻两层的 order，各产生一条 MoveLayerOp。
  void moveLayer(LayerId layerId, {required bool towardTop}) {
    final sorted = state.document.state.layers; // 底 → 顶
    final index = sorted.indexWhere((l) => l.id == layerId);
    final swapIndex = towardTop ? index + 1 : index - 1;
    if (swapIndex < 0 || swapIndex >= sorted.length) return;
    final other = sorted[swapIndex];
    _apply((opId, lamport, wall) => MoveLayerOp(
          opId: opId,
          authorId: 'local',
          lamport: lamport,
          wallTimeMs: wall,
          layerId: other.id,
          newOrder: sorted[index].order,
        ));
    _apply((opId, lamport, wall) => MoveLayerOp(
          opId: opId,
          authorId: 'local',
          lamport: lamport,
          wallTimeMs: wall,
          layerId: layerId,
          newOrder: other.order,
        ));
  }

  void _apply(Op Function(String opId, int lamport, int wallTimeMs) build) {
    state.document.applyOp(
      build(_uuid.v4(), _clock.tick(), DateTime.now().millisecondsSinceEpoch),
    );
    state = state.copyWith(); // 新实例触发刷新
  }


  /// 指针按下：开始一笔。
  void onPointerDown(double x, double y, double? pressure) {
    state = state.copyWith(
      inProgress: [StrokePoint(x: x, y: y, pressure: pressure)],
    );
  }

  /// 指针移动：追加采样点（与上一点距离过近时忽略，减少数据量）。
  void onPointerMove(double x, double y, double? pressure) {
    final points = state.inProgress;
    if (points == null) return;
    final last = points.last;
    final dx = x - last.x, dy = y - last.y;
    if (dx * dx + dy * dy < 1) return;
    state = state.copyWith(inProgress: [...points, StrokePoint(x: x, y: y, pressure: pressure)]);
  }

  /// 指针抬起：定稿笔画并写入文档。
  void onPointerUp() {
    final points = state.inProgress;
    if (points == null || points.isEmpty) {
      state = state.copyWith(clearInProgress: true);
      return;
    }
    final stroke = Stroke(
      id: _uuid.v4(),
      authorId: 'local', // task 4.1 接入真实身份
      layerId: state.activeLayerId,
      tool: state.tool,
      color: state.color,
      width: state.width,
      points: points,
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    state.document.applyOp(
      AddStrokeOp(
        opId: _uuid.v4(),
        authorId: stroke.authorId,
        lamport: _clock.tick(),
        wallTimeMs: stroke.createdAtMs,
        stroke: stroke,
      ),
    );
    state = state.copyWith(clearInProgress: true);
  }

  /// 指针取消：丢弃进行中笔画。
  void onPointerCancel() => state = state.copyWith(clearInProgress: true);

  /// 撤销自己最近一条未撤销的操作（完整撤销/重做在 task 2.3 完善）。
  void undo() {
    for (final op in state.document.log.reversed) {
      if (op.authorId == 'local' &&
          op is! UndoOp &&
          state.document.isEffective(op.opId)) {
        state.document.applyOp(
          UndoOp(
            opId: _uuid.v4(),
            authorId: 'local',
            lamport: _clock.tick(),
            wallTimeMs: DateTime.now().millisecondsSinceEpoch,
            undoneOpId: op.opId,
          ),
        );
        state = state.copyWith(); // 新实例触发界面刷新
        return;
      }
    }
  }
}

final canvasProvider =
    NotifierProvider<CanvasController, CanvasUiState>(CanvasController.new);
