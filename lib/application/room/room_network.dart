import 'dart:async';

import 'package:taraxacum_draw/application/room/room_message.dart';
import 'package:taraxacum_draw/application/room/room_session.dart';
import 'package:taraxacum_draw/domain/envelope.dart';
import 'package:taraxacum_draw/domain/ids.dart';
import 'package:taraxacum_draw/domain/room_state.dart';
import 'package:taraxacum_draw/infrastructure/transport/transport.dart';

/// 房间信令 ↔ 传输层适配（task 4.2 网络接线）。
///
/// - 会话 outbox → 信封 → 各传输广播/定向发送；
/// - 传输入站 roomControl 信封 → 会话状态机；
/// - 对端断开事件 → 会话成员维护（房主侧移除）。
/// 其他类型信封（op/cursor/chat 等）由同步层（task 5.x）处理。
class RoomNetworkAdapter {
  RoomNetworkAdapter({
    required this.session,
    required this.transports,
    this.onChanged,
    this.onPeerJoined,
    this.onHostLost,
  });

  final RoomSession session;
  final List<Transport> transports;

  /// 会话状态变化后的 UI 通知。
  final void Function()? onChanged;

  /// 对端加入（房主侧用于同步补齐，task 5.3）。
  final void Function(PeerId peer)? onPeerJoined;

  /// 成员侧检测到房主失联（触发自动重连，task 5.4）。
  final void Function(PeerId peer)? onHostLost;

  int _seq = 0;
  final List<StreamSubscription> _subs = [];

  /// 订阅各传输事件；返回取消订阅列表（页面销毁时调用）。
  List<StreamSubscription> attach() {
    for (final transport in transports) {
      _subs.add(transport.messages.listen(_onEnvelope));
      _subs.add(transport.peerEvents.listen((event) {
        if (event.kind == PeerEventKind.joined) {
          onPeerJoined?.call(event.peer);
        } else if (session.isHost) {
          session.onDisconnected(event.peer);
          flush();
        } else if (event.peer == session.hostPeerId) {
          // 成员侧：房主失联 → 触发自动重连（task 5.4）。
          onHostLost?.call(event.peer);
        }
      }));
    }
    return List.of(_subs);
  }

  Future<void> dispose() async {
    for (final sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
  }

  void _notify() => onChanged?.call();

  void _onEnvelope(Envelope envelope) {
    if (envelope.type != MessageType.roomControl) return;
    if (envelope.from == session.selfPeerId) return;

    final message = RoomMessage.decode(envelope.payload);
    switch (message.type) {
      case 'state':
        if (!session.isHost) {
          session.onRemoteState(RoomState.fromJson(message.payload));
        }
      case 'joinRejected':
        if (!session.isHost) session.onJoinRejected();
      case 'bye':
        if (session.isHost) session.onDisconnected(envelope.from);
      case 'dissolve':
        if (!session.isHost) session.onRemoteDissolve();
      default:
        break; // hostTransferred / approvalPending：快照或 UI 自行处理
    }
    flush();
    _notify();
  }

  /// 通用发送：会话 outbox → 信封 → 各传输。
  void flush() {
    for (final message in session.drainOutbox()) {
      _deliver(message);
    }
  }

  /// 成员发出加入请求（hello）。
  void sendHello({required String name, required int color}) =>
      _deliver(RoomMessage.broadcast('hello', {'n': name, 'c': color}));

  void _deliver(RoomMessage message) {
    final envelope = message.toEnvelope(
      roomId: session.roomId,
      from: session.selfPeerId,
      seq: ++_seq,
      lamport: 0,
    );
    for (final transport in transports) {
      if (message.to != null) {
        transport.sendTo(envelope, message.to!);
      } else {
        transport.broadcast(envelope);
      }
    }
  }
}
