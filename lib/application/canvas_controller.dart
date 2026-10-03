import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import 'package:taraxacum_draw/domain/canvas_document.dart';
import 'package:taraxacum_draw/domain/ids.dart';
import 'package:taraxacum_draw/domain/lamport_clock.dart';
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
