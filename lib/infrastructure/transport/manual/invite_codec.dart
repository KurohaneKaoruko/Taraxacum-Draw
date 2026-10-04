import 'dart:convert';
import 'dart:io' show ZLibCodec;

import 'package:taraxacum_draw/domain/ids.dart';

/// 邀请载荷：成员仅凭它即可直连房主（无需任何在线服务）。
class InvitePayload {
  const InvitePayload({
    required this.version,
    required this.roomId,
    required this.hostPeerId,
    required this.hostName,
    required this.port,
    required this.ips,
  });

  final int version;
  final RoomId roomId;
  final PeerId hostPeerId;
  final String hostName;
  final int port;

  /// 房主的所有局域网 IPv4 候选（成员按序尝试拨号）。
  final List<String> ips;

  Map<String, Object?> toJson() => {
        'v': version,
        'r': roomId,
        'p': hostPeerId,
        'n': hostName,
        'port': port,
        'ips': ips,
      };

  static InvitePayload fromJson(Map<Object?, Object?> json) {
    final port = (json['port'] as num?)?.toInt();
    final ips = (json['ips'] as List?)?.cast<String>() ?? const [];
    final roomId = json['r'] as String?;
    final hostPeer = json['p'] as String?;
    if (port == null || roomId == null || hostPeer == null) {
      throw const FormatException('邀请载荷缺少必要字段');
    }
    return InvitePayload(
      version: (json['v'] as num?)?.toInt() ?? 1,
      roomId: roomId,
      hostPeerId: hostPeer,
      hostName: (json['n'] as String?) ?? '',
      port: port,
      ips: ips,
    );
  }
}

/// 房主地址的候选（成员拨号用）。
class InviteEndpoint {
  const InviteEndpoint({required this.host, required this.port});

  final String host;
  final int port;
}

/// 应答信息：成员连上后回传给房主的确认。
class AnswerInfo {
  const AnswerInfo({required this.guestPeerId, required this.guestName});

  final PeerId guestPeerId;
  final String guestName;
}

/// 邀请码 / 应答码编解码（task 3.4）。
///
/// 编码：JSON → zlib → base64Url（无填充）。
/// 分帧：`TDI|<序号>|<总数>|<片段>`，片段乱序/分多次扫描皆可，
/// 集齐总数后重组；无法识别的帧抛 FormatException。
class InviteCodec {
  static const String framePrefix = 'TDI';

  /// 单帧二维码的最大字符数（兼顾扫码识别率）。
  static const int maxFrameChars = 800;

  static final ZLibCodec _zlib = ZLibCodec();

  // ===== 邀请码 =====

  static String encodeInvite(InvitePayload payload) =>
      _encodeBytes(utf8.encode(jsonEncode(payload.toJson())));

  static InvitePayload decodeInvite(String code) {
    final json = _decodeBytes(code);
    return InvitePayload.fromJson(json);
  }

  // ===== 应答码 =====

  static String encodeAnswer(AnswerInfo answer) => _encodeBytes(
        utf8.encode(jsonEncode({'p': answer.guestPeerId, 'n': answer.guestName})),
      );

  static AnswerInfo decodeAnswer(String code) {
    final json = _decodeBytes(code);
    final peer = json['p'] as String?;
    if (peer == null) throw const FormatException('应答码缺少成员标识');
    return AnswerInfo(
      guestPeerId: peer,
      guestName: (json['n'] as String?) ?? '',
    );
  }

  // ===== 分帧 =====

  /// 把邀请码文本切分为二维码帧。
  static List<String> toFrames(String code) {
    final total = (code.length / maxFrameChars).ceil();
    final frames = <String>[];
    for (var i = 0; i < total; i++) {
      final start = i * maxFrameChars;
      final end = (start + maxFrameChars).clamp(0, code.length);
      frames.add('$framePrefix|${i + 1}|$total|${code.substring(start, end)}');
    }
    return frames;
  }

  /// 从（可能乱序、可能重复的）帧集合重组邀请码。
  static String fromFrames(Iterable<String> frames) {
    final parts = <int, String>{};
    var total = -1;
    for (final frame in frames) {
      final part = parseFrame(frame);
      if (part == null) continue; // 非 TDI 帧（扫描噪声），忽略
      parts[part.$1] = part.$3;
      total = part.$2;
    }
    if (total <= 0 || parts.length != total) {
      throw const FormatException('邀请码帧不完整');
    }
    return [for (var i = 1; i <= total; i++) parts[i]!].join();
  }

  /// 解析单帧：返回 (序号, 总数, 片段)；非邀请帧返回 null。
  static (int, int, String)? parseFrame(String frame) {
    if (!frame.startsWith('$framePrefix|')) return null;
    final segments = frame.split('|');
    if (segments.length != 4) throw const FormatException('邀请帧格式错误');
    final index = int.tryParse(segments[1]);
    final total = int.tryParse(segments[2]);
    if (index == null || total == null || index < 1 || index > total) {
      throw const FormatException('邀请帧序号非法');
    }
    return (index, total, segments[3]);
  }

  // ===== 内部 =====

  static String _encodeBytes(List<int> bytes) {
    final compressed = _zlib.encode(bytes);
    return base64Url.encode(compressed).replaceAll('=', '');
  }

  static Map<Object?, Object?> _decodeBytes(String code) {
    final normalized = base64Url.normalize('$code${'=' * ((4 - code.length % 4) % 4)}');
    final decompressed = _zlib.decode(base64Url.decode(normalized));
    return jsonDecode(utf8.decode(decompressed)) as Map<Object?, Object?>;
  }
}
