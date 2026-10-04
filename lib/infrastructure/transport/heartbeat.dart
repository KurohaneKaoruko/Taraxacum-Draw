import 'dart:async';
import 'dart:typed_data';

import 'package:taraxacum_draw/domain/envelope.dart';
import 'package:taraxacum_draw/domain/ids.dart';
import 'package:taraxacum_draw/infrastructure/transport/transport.dart';

/// 链路心跳保活（task 3.6）。
///
/// 周期发送 ping；对端收到 ping 由本组件自动回 pong。
/// 任何入站消息都会刷新活跃时间；超过 [timeout] 无流量视为
/// 静默掉线（崩溃/断网无 FIN），以 lost 语义关闭链路。
class LinkHeartbeat {
  LinkHeartbeat({
    required PeerLink link,
    required PeerId selfPeer,
    required RoomId roomId,
    this.interval = const Duration(seconds: 3),
    this.timeout = const Duration(seconds: 10),
  })  : _link = link,
        _selfPeer = selfPeer,
        _roomId = roomId {
    _lastSeen = DateTime.now();
    _sub = link.messages.listen(_onMessage);
    _timer = Timer.periodic(interval, (_) => _tick());
  }

  final PeerLink _link;
  final PeerId _selfPeer;
  final RoomId _roomId;
  final Duration interval;
  final Duration timeout;

  late DateTime _lastSeen;
  Timer? _timer;
  StreamSubscription<Envelope>? _sub;
  bool _stopped = false;

  void _onMessage(Envelope envelope) {
    _lastSeen = DateTime.now();
    if (envelope.type == MessageType.ping && _link.isOpen) {
      // 自动回 pong（忽略失败，发送失败链路自身会感知）。
      _link
          .send(Envelope(
            type: MessageType.pong,
            roomId: envelope.roomId,
            from: _selfPeer,
            seq: 0,
            lamport: 0,
            payload: Uint8List(0),
          ))
          .catchError((_) {});
    }
  }

  void _tick() {
    if (_stopped) return;
    if (!_link.isOpen) return dispose();
    if (DateTime.now().difference(_lastSeen) > timeout) {
      dispose();
      // 静默掉线：以 lost 语义关闭链路（transport 据此发出 lost 事件）。
      _link.close(PeerEventKind.lost).catchError((_) {});
      return;
    }
    _link
        .send(Envelope(
          type: MessageType.ping,
          roomId: _roomId,
          from: _selfPeer,
          seq: 0,
          lamport: 0,
          payload: Uint8List(0),
        ))
        .catchError((_) {});
  }

  void dispose() {
    if (_stopped) return;
    _stopped = true;
    _timer?.cancel();
    _sub?.cancel();
  }
}
