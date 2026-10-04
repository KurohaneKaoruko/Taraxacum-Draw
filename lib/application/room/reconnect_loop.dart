import 'dart:async';

/// 断线重连循环（task 5.4）。
///
/// 在 [window] 时间窗内以 [retryDelay] 间隔反复尝试 [attempt]；
/// 任一次成功即返回 true；窗口耗尽返回 false（上层提示手动重新加入）。
class ReconnectLoop {
  ReconnectLoop({
    required this.attempt,
    this.retryDelay = const Duration(seconds: 2),
    this.window = const Duration(seconds: 30),
  });

  /// 单次重连尝试：成功（重新建立链路并完成握手）返回 true。
  final Future<bool> Function() attempt;
  final Duration retryDelay;
  final Duration window;

  Future<bool> run() async {
    final deadline = DateTime.now().add(window);
    var first = true;
    while (true) {
      if (!first) {
        await Future<void>.delayed(retryDelay);
      }
      first = false;
      if (DateTime.now().isAfter(deadline)) return false;
      try {
        if (await attempt()) return true;
      } catch (_) {
        // 单次失败继续重试，直至窗口耗尽。
      }
    }
  }
}
