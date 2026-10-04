import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import 'package:taraxacum_draw/application/view_transform.dart';
import 'package:taraxacum_draw/domain/canvas_document.dart';
import 'package:taraxacum_draw/domain/ids.dart';
import 'package:taraxacum_draw/domain/lamport_clock.dart';
import 'package:taraxacum_draw/domain/layer.dart';
import 'package:taraxacum_draw/domain/op.dart';
import 'package:taraxacum_draw/domain/stroke.dart';

/// 画布界面状态：文档 + 视图变换 + 进行中笔画 + 当前工具设置。
class CanvasUiState {
  const CanvasUiState({
    required this.document,
    required this.tool,
    required this.color,
    required this.width,
    required this.activeLayerId,
    this.view = const ViewTransform(),
    this.inProgress,
  });

  final CanvasDocument document;
  final DrawTool tool;
  final int color;
  final double width;
  final LayerId activeLayerId;

  /// 视图变换（缩放/平移），只影响显示，不影响画布内容与他人视图。
  final ViewTransform view;

  /// 正在绘制中的笔画（未定稿，不进入文档）。
  final List<StrokePoint>? inProgress;

  CanvasUiState copyWith({
    DrawTool? tool,
    int? color,
    double? width,
    LayerId? activeLayerId,
    ViewTransform? view,
    List<StrokePoint>? inProgress,
    bool clearInProgress = false,
  }) =>
      CanvasUiState(
        document: document,
        tool: tool ?? this.tool,
        color: color ?? this.color,
        width: width ?? this.width,
        activeLayerId: activeLayerId ?? this.activeLayerId,
        view: view ?? this.view,
        inProgress: clearInProgress ? null : (inProgress ?? this.inProgress),
      );
}

/// 画布控制器：指针事件 → 笔画 → AddStrokeOp 入文档。
///
/// 本地产生的每条 op 经 [onLocalOp] 回调交给同步层广播（task 5.1）；
/// 远端 op / 快照经 [applyRemoteOp] / [adoptSnapshot] 进入同一文档。
class CanvasController extends Notifier<CanvasUiState> {
  static const _uuid = Uuid();
  final LamportClock _clock = LamportClock();

  /// 本端作者标识：加入房间时由房间控制器设为 identity.peerId，
  /// 撤销"只作用于本人操作"的判定依赖它。单机默认 'local'。
  String authorId = 'local';

  /// 本地产生的新 op（同步层订阅后广播给房间）。
  void Function(Op op)? onLocalOp;

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
  void setView(ViewTransform view) => state = state.copyWith(view: view);

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
    final op = build(
      _uuid.v4(),
      _clock.tick(),
      DateTime.now().millisecondsSinceEpoch,
    );
    _applyLocal(op);
  }

  void _applyLocal(Op op) {
    state.document.applyOp(op);
    onLocalOp?.call(op);
    state = state.copyWith(); // 新实例触发界面刷新
  }

  /// 当前画布文档（同步层读取 log/状态用）。
  CanvasDocument get document => state.document;

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
      authorId: authorId,
      layerId: state.activeLayerId,
      tool: state.tool,
      color: state.color,
      width: state.width,
      points: points,
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    _apply((opId, lamport, wall) => AddStrokeOp(
          opId: opId,
          authorId: stroke.authorId,
          lamport: lamport,
          wallTimeMs: wall,
          stroke: stroke,
        ));
    state = state.copyWith(clearInProgress: true);
  }

  /// 指针取消：丢弃进行中笔画。
  void onPointerCancel() => state = state.copyWith(clearInProgress: true);

  /// 撤销自己最近一条未撤销的操作。
  void undo() {
    for (final op in state.document.log.reversed) {
      if (op.authorId == authorId &&
          op is! UndoOp &&
          state.document.isEffective(op.opId)) {
        _applyUndoOf(op.opId);
        return;
      }
    }
  }

  /// 重做：恢复最近一次被撤销的用户操作。
  ///
  /// 只考虑"实际压制了非撤销类操作"的生效撤销 op（跳过 redo 机制
  /// 自身产生的撤销的撤销），取日志中最新的一条，撤销它。
  void redo() {
    final doc = state.document;
    for (final op in doc.log.reversed) {
      if (op is! UndoOp || op.authorId != authorId) continue;
      if (!doc.isEffective(op.opId)) continue;

      Op? target;
      for (final candidate in doc.log) {
        if (candidate.opId == op.undoneOpId) {
          target = candidate;
          break;
        }
      }
      if (target == null || target is UndoOp) continue;
      if (doc.isEffective(target.opId)) continue;
      _applyUndoOf(op.opId);
      return;
    }
  }

  void _applyUndoOf(String targetOpId) {
    _apply((opId, lamport, wall) => UndoOp(
          opId: opId,
          authorId: authorId,
          lamport: lamport,
          wallTimeMs: wall,
          undoneOpId: targetOpId,
        ));
  }

  /// 清空画布（保留图层结构；UI 侧需先弹确认，见 drawing-canvas 规格）。
  void clearCanvas() {
    _apply((opId, lamport, wall) =>
        ClearCanvasOp(opId: opId, authorId: 'local', lamport: lamport, wallTimeMs: wall));
  }

  /// 应用远端 op（同步层入口，task 5.1）。
  void applyRemoteOp(Op op) {
    _clock.merge(op.lamport);
    state.document.applyOp(op);
    state = state.copyWith();
  }

  /// 应用远端快照（中途加入 / 重连补齐，task 5.3/5.6）。
  void adoptSnapshot(CanvasState snapshot) {
    state.document.seedFromState(snapshot);
    state = state.copyWith();
  }
}

final canvasProvider =
    NotifierProvider<CanvasController, CanvasUiState>(CanvasController.new);
