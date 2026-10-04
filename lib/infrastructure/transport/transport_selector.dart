import 'dart:async';

import 'package:taraxacum_draw/infrastructure/transport/transport.dart';

/// 一次自动加入尝试（选择器按序执行）。
class AutoJoinAttempt {
  AutoJoinAttempt({required this.mode, required this.attempt});

  final ConnectionMode mode;

  /// 尝试加入并返回链路；失败应抛异常。
  /// LAN 实现内部须自带 1–2s 探测超时（p2p-transport 规格）。
  final Future<PeerLink> Function() attempt;
}

/// 加入选择结果。
sealed class JoinSelection {
  const JoinSelection();
}

/// 自动加入成功。
class AutoJoined extends JoinSelection {
  const AutoJoined({required this.mode, required this.link});

  final ConnectionMode mode;
  final PeerLink link;
}

/// 自动链全部失败：进入手动流程（扫码 / 粘贴邀请码）。
class NeedsManual extends JoinSelection {
  const NeedsManual({required this.errors});

  /// 各自动方式的失败原因（UI 展示用）。
  final Map<ConnectionMode, String> errors;
}

/// 全部方式失败（含手动不可用）。
class JoinFailed extends JoinSelection {
  const JoinFailed({required this.errors});

  final Map<ConnectionMode, String> errors;
}

/// 传输选择器（task 3.5）：局域网 → 跨网 → 手动 的自动降级链。
///
/// 上层（加入流程）只依赖本类与 [JoinSelection]；[AutoJoinAttempt]
/// 由各传输组装，便于用记录调用顺序的假实现测试降级逻辑。
class TransportSelector {
  TransportSelector({
    required this.autoAttempts,
    this.manualAvailable = true,
    this.perAttemptTimeout = const Duration(seconds: 2),
  });

  /// 有序的自动尝试（约定：LAN 在前，WebRTC 在后）。
  final List<AutoJoinAttempt> autoAttempts;

  /// 手动信令兜底是否可用。
  final bool manualAvailable;

  /// 单次尝试的硬超时（规格：LAN 探测 1–2s）。
  final Duration perAttemptTimeout;

  Future<JoinSelection> selectAndJoin() async {
    final errors = <ConnectionMode, String>{};
    for (final attempt in autoAttempts) {
      try {
        final link =
            await attempt.attempt().timeout(perAttemptTimeout);
        return AutoJoined(mode: attempt.mode, link: link);
      } catch (error) {
        errors[attempt.mode] = error.toString();
      }
    }
    if (manualAvailable) return NeedsManual(errors: errors);
    return JoinFailed(errors: errors);
  }
}
