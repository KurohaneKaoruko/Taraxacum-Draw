import 'ids.dart';
import 'layer.dart';
import 'stroke.dart';

/// 操作类型标签，用于编解码与调试。
enum OpKind {
  addStroke,
  undo,
  clearCanvas,
  addLayer,
  removeLayer,
  moveLayer,
  setLayerVisible,
}

/// 画布操作的基类（design.md D3：op-log 全序重放模型）。
///
/// 不可变；所有端按 `(lamport, authorId)` 全序重放得到一致状态。
/// 撤销不是"删除历史"，而是追加一条 [UndoOp] 指向目标 opId。
sealed class Op implements Comparable<Op> {
  Op({
    required this.opId,
    required this.authorId,
    required this.lamport,
    required this.wallTimeMs,
  });

  final OpId opId;
  final PeerId authorId;

  /// 产生该操作时的 Lamport 时钟值（全序主键之一）。
  final int lamport;

  /// 本地墙钟（毫秒），仅展示用，不参与排序。
  final int wallTimeMs;

  OpKind get kind;

  /// 全序：先按 lamport，再按 authorId 字典序（design.md D3/D7）。
  @override
  int compareTo(Op other) => compareOps(this, other);

  @override
  String toString() =>
      '$runtimeType(opId: $opId, author: $authorId, lamport: $lamport)';
}

/// 追加一笔。
class AddStrokeOp extends Op {
  AddStrokeOp({
    required super.opId,
    required super.authorId,
    required super.lamport,
    required super.wallTimeMs,
    required this.stroke,
  });

  final Stroke stroke;

  @override
  OpKind get kind => OpKind.addStroke;
}

/// 撤销：只允许撤销自己的操作（见 drawing-canvas 规格）。
class UndoOp extends Op {
  UndoOp({
    required super.opId,
    required super.authorId,
    required super.lamport,
    required super.wallTimeMs,
    required this.undoneOpId,
  });

  final OpId undoneOpId;

  @override
  OpKind get kind => OpKind.undo;
}

/// 清空画布（可撤销：undo 指向本 op 即恢复）。
class ClearCanvasOp extends Op {
  ClearCanvasOp({
    required super.opId,
    required super.authorId,
    required super.lamport,
    required super.wallTimeMs,
  });

  @override
  OpKind get kind => OpKind.clearCanvas;
}

/// 新建图层。
class AddLayerOp extends Op {
  AddLayerOp({
    required super.opId,
    required super.authorId,
    required super.lamport,
    required super.wallTimeMs,
    required this.layer,
  });

  final Layer layer;

  @override
  OpKind get kind => OpKind.addLayer;
}

/// 删除图层（其上笔迹一并失效）。
class RemoveLayerOp extends Op {
  RemoveLayerOp({
    required super.opId,
    required super.authorId,
    required super.lamport,
    required super.wallTimeMs,
    required this.layerId,
  });

  final LayerId layerId;

  @override
  OpKind get kind => OpKind.removeLayer;
}

/// 调整图层叠放顺序。
class MoveLayerOp extends Op {
  MoveLayerOp({
    required super.opId,
    required super.authorId,
    required super.lamport,
    required super.wallTimeMs,
    required this.layerId,
    required this.newOrder,
  });

  final LayerId layerId;
  final int newOrder;

  @override
  OpKind get kind => OpKind.moveLayer;
}

/// 切换图层可见性。
class SetLayerVisibleOp extends Op {
  SetLayerVisibleOp({
    required super.opId,
    required super.authorId,
    required super.lamport,
    required super.wallTimeMs,
    required this.layerId,
    required this.visible,
  });

  final LayerId layerId;
  final bool visible;

  @override
  OpKind get kind => OpKind.setLayerVisible;
}

/// op 全序比较器：`(lamport, authorId)`。
///
/// 全序性依赖不变量：同一 authorId 的 lamport 严格递增
/// （由 [LamportClock.tick] 每次本地操作自增保证），因此同键冲突
/// 只可能出现在完全相同的 op 上。
int compareOps(Op a, Op b) {
  final byLamport = a.lamport.compareTo(b.lamport);
  if (byLamport != 0) return byLamport;
  return a.authorId.compareTo(b.authorId);
}
