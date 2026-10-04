import 'dart:convert';
import 'dart:typed_data';

import 'package:taraxacum_draw/domain/envelope.dart';
import 'package:taraxacum_draw/domain/ids.dart';

/// 房间控制消息（经 Envelope(type: roomControl) 承载）。
class RoomMessage {
  RoomMessage.broadcast(this.type, this.payload) : to = null;

  RoomMessage.to(this.to, this.type, this.payload);

  /// null = 广播全员。
  final PeerId? to;
  final String type; // state / joinRejected / setRole / bye / dissolve
  final Map<String, Object?> payload;

  Envelope toEnvelope({
    required RoomId roomId,
    required PeerId from,
    required int seq,
    required int lamport,
  }) =>
      Envelope(
        type: MessageType.roomControl,
        roomId: roomId,
        from: from,
        seq: seq,
        lamport: lamport,
        payload: Uint8List.fromList(
          utf8.encode(jsonEncode({'rt': type, ...payload})),
        ),
      );

  static RoomMessage decode(Uint8List payloadBytes) {
    final json =
        jsonDecode(utf8.decode(payloadBytes)) as Map<String, Object?>;
    final type = json.remove('rt') as String? ?? '';
    return RoomMessage.broadcast(type, json);
  }
}
