import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:taraxacum_draw/domain/envelope.dart';
import 'package:taraxacum_draw/domain/ids.dart';
import 'package:taraxacum_draw/infrastructure/transport/transport.dart';

/// 远端光标（画布逻辑坐标）。
class RemoteCursor {
  const RemoteCursor({
    required this.peerId,
    required this.name,
    required this.color,
    required this.x,
    required this.y,
    required this.lastSeenMs,
  });

  final PeerId peerId;
  final String name;
  final int color;
  final double x;
  final double y;
  final int lastSeenMs;
}

/// 一条聊天消息。
class ChatMessage {
  const ChatMessage({
    required this.peerId,
    required this.name,
    required this.color,
    required this.text,
    required this.timeMs,
  });

  final PeerId peerId;
  final String name;
  final int color;
  final String text;
  final int timeMs;
}

/// 协作感知状态（task 6.1–6.4）。
class PresenceState {
  const PresenceState({
    this.cursors = const {},
    this.messages = const [],
    this.showRemoteCursors = true,
  });

  final Map<PeerId, RemoteCursor> cursors;
  final List<ChatMessage> messages;

  /// 是否显示他人光标（6.4 设置开关）。
  final bool showRemoteCursors;

  PresenceState copyWith({
    Map<PeerId, RemoteCursor>? cursors,
    List<ChatMessage>? messages,
    bool? showRemoteCursors,
  }) =>
      PresenceState(
        cursors: cursors ?? this.cursors,
        messages: messages ?? this.messages,
        showRemoteCursors: showRemoteCursors ?? this.showRemoteCursors,
      );
}

/// 协作感知控制器：远端光标 / 聊天 / 开关。
///
/// [onLocalPointer] 由画布输入区在指针移动时调用；发送节流 ~30Hz。
/// 光标/聊天均通过广播信封（type: cursor/chat）分发，全员可见。
class PresenceController extends Notifier<PresenceState> {
  /// 光标发送最小间隔（≥30Hz 上限即间隔 ≥33ms）。
  static const Duration _sendInterval = Duration(milliseconds: 33);

  final List<Transport> _transports = [];
  final List<StreamSubscription> _subs = [];
  DateTime _lastSent = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  PresenceState build() => const PresenceState();

  /// 进入房间时绑定传输；离开时解绑。
  void bind(List<Transport> transports) {
    _transports.clear();
    _transports.addAll(transports);
    for (final transport in transports) {
      _subs.add(transport.messages.listen(_onEnvelope));
    }
  }

  void unbind() {
    for (final sub in _subs) {
      sub.cancel();
    }
    _subs.clear();
    _transports.clear();
    state = const PresenceState();
  }

  // ===== 光标 =====

  /// 本端指针在画布坐标系的移动（节流后广播）。
  void onLocalPointer({
    required String selfPeerId,
    required String selfName,
    required int selfColor,
    required double x,
    required double y,
  }) {
    final now = DateTime.now();
    if (now.difference(_lastSent) < _sendInterval) return;
    _lastSent = now;
    _broadcast({
      'x': x,
      'y': y,
      'n': selfName,
      'c': selfColor,
    }, type: MessageType.cursor);
  }

  /// 移除某成员的光标（离开/断线）。
  void removePeer(PeerId peer) {
    if (!state.cursors.containsKey(peer)) return;
    state = state.copyWith(
      cursors: Map.of(state.cursors)..remove(peer),
    );
  }

  // ===== 聊天 =====

  void sendChat({
    required String selfPeerId,
    required String selfName,
    required int selfColor,
    required String text,
  }) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    final now = DateTime.now();
    _broadcast({
      't': trimmed,
      'n': selfName,
      'c': selfColor,
      'ms': now.millisecondsSinceEpoch,
    }, type: MessageType.chat);
    // 本地立即入列（会话内消息对自己可见）。
    state = state.copyWith(messages: [
      ...state.messages,
      ChatMessage(
        peerId: selfPeerId,
        name: selfName,
        color: selfColor,
        text: trimmed,
        timeMs: now.millisecondsSinceEpoch,
      ),
    ]);
  }

  // ===== 开关（6.4）=====

  void toggleRemoteCursors() =>
      state = state.copyWith(showRemoteCursors: !state.showRemoteCursors);

  // ===== 内部 =====

  void _broadcast(Map<String, Object?> payload,
      {required MessageType type}) {
    final envelope = Envelope(
      type: type,
      roomId: _roomId,
      from: _selfPeerId,
      seq: 0,
      lamport: 0,
      payload: Uint8List.fromList(utf8.encode(jsonEncode(payload))),
    );
    for (final transport in _transports) {
      transport.broadcast(envelope);
    }
  }

  /// 加入房间时由房间控制器设置。
  PeerId _selfPeerId = '';
  String _roomId = '';

  void configure({required PeerId selfPeerId, required RoomId roomId}) {
    _selfPeerId = selfPeerId;
    _roomId = roomId;
  }

  void _onEnvelope(Envelope envelope) {
    if (envelope.from == _selfPeerId) return;
    final json =
        jsonDecode(utf8.decode(envelope.payload)) as Map<String, Object?>;
    switch (envelope.type) {
      case MessageType.cursor:
        final cursor = RemoteCursor(
          peerId: envelope.from,
          name: (json['n'] as String?) ?? '',
          color: ((json['c'] as num?) ?? 0xFF888888).toInt(),
          x: ((json['x'] as num?) ?? 0).toDouble(),
          y: ((json['y'] as num?) ?? 0).toDouble(),
          lastSeenMs: DateTime.now().millisecondsSinceEpoch,
        );
        state = state.copyWith(
          cursors: {...state.cursors, envelope.from: cursor},
        );
      case MessageType.chat:
        state = state.copyWith(messages: [
          ...state.messages,
          ChatMessage(
            peerId: envelope.from,
            name: (json['n'] as String?) ?? '',
            color: ((json['c'] as num?) ?? 0xFF888888).toInt(),
            text: (json['t'] as String?) ?? '',
            timeMs: ((json['ms'] as num?) ?? 0).toInt(),
          ),
        ]);
      default:
        break;
    }
  }
}

final presenceProvider =
    NotifierProvider<PresenceController, PresenceState>(
        PresenceController.new);
