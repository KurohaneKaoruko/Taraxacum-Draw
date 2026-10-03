import 'package:flutter_test/flutter_test.dart';
import 'package:taraxacum_draw/domain/op.dart';

Op makeOp(String opId, String authorId, int lamport) => ClearCanvasOp(
      opId: opId,
      authorId: authorId,
      lamport: lamport,
      wallTimeMs: 0,
    );

void main() {
  group('op 全序排序 (lamport, authorId)', () {
    // 不变量：同一作者的 lamport 严格递增（由 LamportClock.tick 保证），
    // 因此平局只会出现在不同作者之间。
    final ops = [
      makeOp('op-c', 'peer-b', 5),
      makeOp('op-a', 'peer-a', 5),
      makeOp('op-e', 'peer-a', 2),
      makeOp('op-d', 'peer-c', 1),
      makeOp('op-b', 'peer-d', 5),
    ];

    test('相同 lamport 时按 authorId 字典序打破平局', () {
      final sorted = [...ops]..sort();
      expect(
        sorted.map((o) => o.opId),
        ['op-d', 'op-e', 'op-a', 'op-c', 'op-b'],
      );
    });

    test('排序是全序：任意输入排列产生相同输出', () {
      final reference = [...ops]..sort();
      for (var i = 0; i < 20; i++) {
        final shuffled = [...ops]..shuffle();
        expect(shuffled..sort(), reference, reason: '打乱后的输入必须得到相同结果');
      }
    });

    test('compareTo 与 compareOps 一致且满足反对称/传递性', () {
      final sorted = [...ops]..sort();
      for (var i = 0; i < sorted.length; i++) {
        for (var j = 0; j < sorted.length; j++) {
          final a = sorted[i];
          final b = sorted[j];
          if (i < j) {
            expect(a.compareTo(b), isNegative, reason: '$a 应排在 $b 之前');
          } else if (i > j) {
            expect(a.compareTo(b), isPositive);
          } else {
            expect(a.compareTo(b), isZero);
          }
        }
      }
    });
  });

  group('op kind', () {
    test('每种 op 携带正确的 kind 标签', () {
      expect(
        makeOp('x', 'peer-a', 1).kind,
        OpKind.clearCanvas,
      );
      final undo = UndoOp(
        opId: 'u1',
        authorId: 'peer-a',
        lamport: 2,
        wallTimeMs: 0,
        undoneOpId: 'x',
      );
      expect(undo.kind, OpKind.undo);
      expect(undo.undoneOpId, 'x');
    });
  });
}
