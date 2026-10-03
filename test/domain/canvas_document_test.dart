import 'package:flutter_test/flutter_test.dart';
import 'package:taraxacum_draw/domain/canvas_document.dart';
import 'package:taraxacum_draw/domain/layer.dart';
import 'package:taraxacum_draw/domain/op.dart';
import 'package:taraxacum_draw/domain/stroke.dart';

AddStrokeOp strokeOp(String id, String author, int lamport, String strokeId,
        {String layerId = 'base'}) =>
    AddStrokeOp(
      opId: id,
      authorId: author,
      lamport: lamport,
      wallTimeMs: 0,
      stroke: Stroke(
        id: strokeId,
        authorId: author,
        layerId: layerId,
        tool: DrawTool.brush,
        color: 0xFF000000,
        width: 4,
        points: const [StrokePoint(x: 0, y: 0), StrokePoint(x: 10, y: 10)],
        createdAtMs: 0,
      ),
    );

void main() {
  group('CanvasDocument', () {
    test('初始文档带基础图层', () {
      final doc = CanvasDocument();
      expect(doc.state.layers.map((l) => l.id), ['base']);
    });

    test('AddStroke 快路径追加', () {
      final doc = CanvasDocument()..applyOp(strokeOp('o1', 'a', 1, 's1'));
      expect(doc.strokesOf('base').length, 1);
      final v = doc.version;
      doc.applyOp(strokeOp('o2', 'a', 2, 's2'));
      expect(doc.strokesOf('base').length, 2);
      expect(doc.version, greaterThan(v));
    });

    test('撤销移除指定笔画，撤销撤销（重做）恢复', () {
      final doc = CanvasDocument()
        ..applyOp(strokeOp('o1', 'a', 1, 's1'))
        ..applyOp(strokeOp('o2', 'a', 2, 's2'));

      doc.applyOp(UndoOp(
        opId: 'u1', authorId: 'a', lamport: 3, wallTimeMs: 0, undoneOpId: 'o2',
      ));
      expect(doc.strokesOf('base').map((s) => s.id), ['s1']);

      // 重做 = 撤销那条撤销。
      doc.applyOp(UndoOp(
        opId: 'u2', authorId: 'a', lamport: 4, wallTimeMs: 0, undoneOpId: 'u1',
      ));
      expect(doc.strokesOf('base').map((s) => s.id), ['s1', 's2']);
    });

    test('清空画布后可通过撤销恢复', () {
      final doc = CanvasDocument()
        ..applyOp(strokeOp('o1', 'a', 1, 's1'))
        ..applyOp(strokeOp('o2', 'a', 2, 's2'));

      doc.applyOp(ClearCanvasOp(
        opId: 'c1', authorId: 'a', lamport: 3, wallTimeMs: 0,
      ));
      expect(doc.strokesOf('base'), isEmpty);
      expect(doc.state.layers.map((l) => l.id), contains('base'), reason: '图层保留');

      doc.applyOp(UndoOp(
        opId: 'u1', authorId: 'a', lamport: 4, wallTimeMs: 0, undoneOpId: 'c1',
      ));
      expect(doc.strokesOf('base').map((s) => s.id), ['s1', 's2']);
    });

    test('乱序到达（同步场景）：最终状态与按全序重放一致', () {
      final doc = CanvasDocument()
        ..applyOp(strokeOp('late', 'b', 5, 's-late'))
        ..applyOp(strokeOp('o1', 'a', 1, 's1'))
        ..applyOp(strokeOp('o2', 'a', 2, 's2'));

      final reference = CanvasDocument()
        ..applyOp(strokeOp('o1', 'a', 1, 's1'))
        ..applyOp(strokeOp('o2', 'a', 2, 's2'))
        ..applyOp(strokeOp('late', 'b', 5, 's-late'));

      expect(
        doc.strokesOf('base').map((s) => s.id),
        reference.strokesOf('base').map((s) => s.id),
        reason: '乱序注入必须收敛到与顺序注入相同的状态',
      );
    });

    test('图层操作重放：新建/排序/可见性', () {
      final doc = CanvasDocument()
        ..applyOp(AddLayerOp(
          opId: 'l1', authorId: 'a', lamport: 1, wallTimeMs: 0,
          layer: const Layer(id: 'sky', name: '天空', order: 1),
        ))
        ..applyOp(SetLayerVisibleOp(
          opId: 'v1', authorId: 'a', lamport: 2, wallTimeMs: 0,
          layerId: 'sky', visible: false,
        ))
        ..applyOp(MoveLayerOp(
          opId: 'm1', authorId: 'a', lamport: 3, wallTimeMs: 0,
          layerId: 'sky', newOrder: -1,
        ));

      final sky = doc.state.layers.firstWhere((l) => l.id == 'sky');
      expect(sky.visible, isFalse);
      expect(sky.order, -1);

      // 新图层上可以画，删除图层后其笔画一并消失。
      doc.applyOp(strokeOp('s3', 'a', 4, 's3', layerId: 'sky'));
      expect(doc.strokesOf('sky').length, 1);
      doc.applyOp(RemoveLayerOp(
        opId: 'r1', authorId: 'a', lamport: 5, wallTimeMs: 0, layerId: 'sky',
      ));
      expect(doc.state.layers.map((l) => l.id), ['base']);
      expect(doc.strokesOf('sky'), isEmpty);
    });
  });
}
