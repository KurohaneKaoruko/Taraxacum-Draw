import 'dart:typed_data';

import 'ids.dart';

/// 网络消息类型（传输层之上、房间/同步层之下的统一信封分类）。
enum MessageType {
  /// 画布操作（单条或批量）。
  op,

  /// op-log 补齐/补发数据。
  sync,

  /// 存在感：光标位置。
  cursor,

  /// 存在感：成员状态（加入/离开/昵称/权限）。
  presence,

  /// 文字聊天。
  chat,

  /// 房间控制（审批、只读、解散等）。
  roomControl,

  /// 心跳。
  ping,

  pong,
}

/// 传输层统一消息信封（design.md D7）。
///
/// 传输实现只负责把信封可靠送达，不理解 payload 内容。
class Envelope {
  const Envelope({
    required this.type,
    required this.roomId,
    required this.from,
    required this.seq,
    required this.lamport,
    required this.payload,
  });

  final MessageType type;
  final RoomId roomId;
  final PeerId from;

  /// 发送方会话内单调递增序号，接收方据此检测缺口并请求重传。
  final int seq;

  /// 发送时的 Lamport 时钟值。
  final int lamport;

  final Uint8List payload;
}
