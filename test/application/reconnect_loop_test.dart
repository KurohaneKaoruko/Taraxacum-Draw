import 'package:flutter_test/flutter_test.dart';
import 'package:taraxacum_draw/application/room/reconnect_loop.dart';

void main() {
  test('失败两次后第三次成功', () async {
    var calls = 0;
    final loop = ReconnectLoop(
      attempt: () async {
        calls++;
        return calls >= 3;
      },
      retryDelay: const Duration(milliseconds: 5),
      window: const Duration(seconds: 2),
    );

    expect(await loop.run(), isTrue);
    expect(calls, 3);
  });

  test('首次尝试成功不等待', () async {
    var calls = 0;
    final loop = ReconnectLoop(
      attempt: () async {
        calls++;
        return true;
      },
      retryDelay: const Duration(seconds: 5),
      window: const Duration(seconds: 30),
    );

    final sw = Stopwatch()..start();
    expect(await loop.run(), isTrue);
    expect(sw.elapsedMilliseconds, lessThan(1000));
    expect(calls, 1);
  });

  test('窗口耗尽返回 false（提示手动重新加入）', () async {
    var calls = 0;
    final loop = ReconnectLoop(
      attempt: () async {
        calls++;
        return false;
      },
      retryDelay: const Duration(milliseconds: 5),
      window: const Duration(milliseconds: 60),
    );

    expect(await loop.run(), isFalse);
    expect(calls, greaterThan(1), reason: '窗口内应持续重试');
  });

  test('单次尝试抛异常不中断循环', () async {
    var calls = 0;
    final loop = ReconnectLoop(
      attempt: () async {
        calls++;
        if (calls < 3) throw StateError('网络错误');
        return true;
      },
      retryDelay: const Duration(milliseconds: 5),
      window: const Duration(seconds: 2),
    );

    expect(await loop.run(), isTrue);
    expect(calls, 3);
  });
}
