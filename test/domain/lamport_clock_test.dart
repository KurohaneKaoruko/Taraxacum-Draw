import 'package:flutter_test/flutter_test.dart';
import 'package:taraxacum_draw/domain/lamport_clock.dart';

void main() {
  group('LamportClock', () {
    test('tick 每次自增 1', () {
      final clock = LamportClock();
      expect(clock.value, 0);
      expect(clock.tick(), 1);
      expect(clock.tick(), 2);
      expect(clock.tick(), 3);
      expect(clock.value, 3);
    });

    test('merge 取 max(local, remote) + 1', () {
      final clock = LamportClock();
      clock.tick();
      clock.tick(); // local = 2

      expect(clock.merge(10), 11); // max(2,10)+1
      expect(clock.value, 11);

      expect(clock.merge(5), 12); // max(11,5)+1
      expect(clock.value, 12);
    });

    test('两端各自 merge 同一远端值后收敛到相同值', () {
      final a = LamportClock()..tick()..tick(); // 2
      final b = LamportClock()..tick(); // 1

      final aVal = a.merge(7);
      final bVal = b.merge(7);
      expect(aVal, bVal, reason: '相同输入必须产生相同的合并结果');

      // 此后任一端 tick 都严格大于合并值，保持因果序。
      expect(a.tick(), greaterThan(aVal));
    });

    test('因果链：远端先 merge 后再传播，本地 merge 严格递增', () {
      final alice = LamportClock();
      final bob = LamportClock();

      final op1 = alice.tick(); // alice 本地画一笔 → 1
      final op2 = bob.merge(op1); // bob 收到后 merge → 2
      final op3 = bob.tick(); // bob 本地画一笔 → 3
      final op4 = alice.merge(op3); // alice 收到 bob 的笔画 → 4

      expect(op1 < op2, isTrue);
      expect(op2 < op3, isTrue);
      expect(op3 < op4, isTrue, reason: '因果顺序上 lamport 必须严格递增');
    });
  });
}
