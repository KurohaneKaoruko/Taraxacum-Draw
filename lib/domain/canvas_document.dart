import 'ids.dart';
import 'layer.dart';
import 'op.dart';
import 'stroke.dart';

/// op-log 重放得到的画布快照（只读视图）。
class CanvasState {
  const CanvasState({required this.layers, required this.strokesByLayer});

  /// 全部图层，按 order 升序（底 → 顶）。
  final List<Layer> layers;

  final Map<LayerId, List<Stroke>> strokesByLayer;
}

/// 画布文档：op-log + 派生状态（design.md D3）。
///
/// - 新到 op 的 lamport 为当前最大值且是 AddStroke 时走 O(1) 快路径追加；
///   其余情况（undo、清空、图层操作、同步乱序到达）全量重放，正确性优先。
/// - 撤销语义：生效 op 集 = log \\ undone；"撤销一条撤销"天然等价于重做。
class CanvasDocument {
  CanvasDocument() {
    // 基础图层作为第一条 op 参与重放，保证所有状态都由 op 派生。
    _log.add(
      AddLayerOp(
        opId: 'base-layer',
        authorId: 'system',
        lamport: 0,
        wallTimeMs: 0,
        layer: const Layer(id: 'base', name: '图层 1', order: 0),
      ),
    );
    _rebuild();
  }

  final List<Op> _log = [];
  List<Layer> _layers = [];
  Map<LayerId, List<Stroke>> _strokes = {};
  int _maxLamport = 0;

  int _version = 0;

  /// 文档版本号，每次状态变化自增；渲染层用于失效判断。
  int get version => _version;

  /// 完整 op-log（到达顺序，供同步补发/快照使用）。
  List<Op> get log => List.unmodifiable(_log);

  CanvasState get state =>
      CanvasState(layers: List.unmodifiable(_layers), strokesByLayer: _viewOf(_strokes));

  List<Stroke> strokesOf(LayerId layerId) =>
      List.unmodifiable(_strokes[layerId] ?? const <Stroke>[]);

  /// 应用一条新操作（本地产生或网络接收）。
  void applyOp(Op op) {
    final inOrder = op.lamport >= _maxLamport;
    if (op.lamport > _maxLamport) _maxLamport = op.lamport;
    _log.add(op);

    if (inOrder && op is AddStrokeOp && isEffective(op.opId)) {
      // 快路径：顺序追加，不触发全量重放。
      _strokes.putIfAbsent(op.stroke.layerId, () => <Stroke>[]).add(op.stroke);
      _version++;
    } else {
      _rebuild();
    }
  }

  /// 判断一条 op 当前是否生效。
  ///
  /// op 失效当且仅当存在一条指向它的 UndoOp 且该 UndoOp 自身生效；
  /// 递归定义天然支持"撤销的撤销 = 重做"的嵌套链。
  bool isEffective(OpId opId) {
    for (final op in _log) {
      if (op is UndoOp && op.undoneOpId == opId && isEffective(op.opId)) {
        return false;
      }
    }
    return true;
  }

  /// 全量重放：生效 op 按 (lamport, authorId) 全序重放。
  void _rebuild() {
    final effective = _log.where((o) => isEffective(o.opId)).toList()
      ..sort(compareOps);

    final layers = <LayerId, Layer>{};
    final strokes = <LayerId, List<Stroke>>{};
    for (final op in effective) {
      switch (op) {
        case AddLayerOp(:final layer):
          layers[layer.id] = layer;
          strokes[layer.id] = <Stroke>[];
        case RemoveLayerOp(:final layerId):
          layers.remove(layerId);
          strokes.remove(layerId);
        case MoveLayerOp(:final layerId, :final newOrder):
          final layer = layers[layerId];
          if (layer != null) layers[layerId] = layer.copyWith(order: newOrder);
        case SetLayerVisibleOp(:final layerId, :final visible):
          final layer = layers[layerId];
          if (layer != null) layers[layerId] = layer.copyWith(visible: visible);
        case ClearCanvasOp():
          strokes.updateAll((_, _) => <Stroke>[]);
        case AddStrokeOp(:final stroke):
          if (layers.containsKey(stroke.layerId)) {
            strokes.putIfAbsent(stroke.layerId, () => <Stroke>[]).add(stroke);
          }
        case UndoOp():
          break; // 其效果已通过 undone 集体现
      }
    }
    _layers = layers.values.toList()..sort((a, b) => a.order.compareTo(b.order));
    _strokes = strokes;
    _version++;
  }

  static Map<LayerId, List<Stroke>> _viewOf(Map<LayerId, List<Stroke>> source) =>
      source.map((key, value) => MapEntry(key, List.unmodifiable(value)));
}
