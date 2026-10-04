import 'dart:convert';
import 'dart:io' show BytesBuilder, ZLibCodec;
import 'dart:typed_data';

import 'package:taraxacum_draw/domain/envelope.dart';

/// Envelope 二进制编解码与传输帧（task 3.1）。
///
/// 信封帧布局（大端序）：
/// ```
/// magic 'T''D' (2) | version (1) | flags (1) | type (1)
/// roomIdLen (2) | roomId (utf8) | fromLen (2) | from (utf8)
/// toLen (2) | to (utf8, 空=广播) | seq (4) | lamport (8)
/// payloadLen (4) | payload
/// ```
/// flags bit0 = payload 已 zlib 压缩。
///
/// 传输帧 = [frameLen (4, 大端)][信封帧]；TCP 与 DataChannel 统一使用。
class EnvelopeCodec {
  static const int magic0 = 0x54; // 'T'
  static const int magic1 = 0x44; // 'D'
  static const int version = 1;
  static const int flagCompressed = 0x01;

  /// 超过该长度的 payload 才启用压缩（小包压缩反而更大）。
  static const int compressionThreshold = 256;

  static const int _maxPayload = 16 * 1024 * 1024;

  static final ZLibCodec _zlib = ZLibCodec();

  static Uint8List encode(Envelope envelope) {
    final roomId = utf8.encode(envelope.roomId);
    final from = utf8.encode(envelope.from);
    final to = utf8.encode(envelope.to ?? '');
    if (roomId.length > 0xFFFF || from.length > 0xFFFF || to.length > 0xFFFF) {
      throw FormatException('roomId/from/to 过长');
    }

    var payload = envelope.payload;
    var flags = 0;
    if (payload.length >= compressionThreshold) {
      payload = Uint8List.fromList(_zlib.encode(payload));
      flags |= flagCompressed;
    }
    if (payload.length > _maxPayload) {
      throw FormatException('payload 过大: ${payload.length}');
    }

    // 固定头部 27 字节（magic2 + version1 + flags1 + type1 +
    // roomIdLen2 + fromLen2 + toLen2 + seq4 + lamport8 + payloadLen4）；
    // 变长的 roomId/from/to/payload 在头部之后按序追加。
    const headerLength = 27;
    final result = BytesBuilder(copy: false);
    final header = ByteData(headerLength);
    var o = 0;
    header
      ..setUint8(o, magic0)
      ..setUint8(o + 1, magic1)
      ..setUint8(o + 2, version)
      ..setUint8(o + 3, flags);
    o += 4;
    header
      ..setUint8(o, envelope.type.index)
      ..setUint16(o + 1, roomId.length, Endian.big)
      ..setUint16(o + 3, from.length, Endian.big)
      ..setUint16(o + 5, to.length, Endian.big)
      ..setUint32(o + 7, envelope.seq, Endian.big)
      ..setUint64(o + 11, envelope.lamport, Endian.big)
      ..setUint32(o + 19, payload.length, Endian.big);
    o += 23;
    result.add(header.buffer.asUint8List(0, headerLength));
    result.add(roomId);
    result.add(from);
    result.add(to);
    result.add(payload);
    return result.toBytes();
  }

  static Envelope decode(Uint8List bytes) {
    if (bytes.length < 27) {
      throw const FormatException('帧过短');
    }
    final data = ByteData.sublistView(bytes);
    if (data.getUint8(0) != magic0 || data.getUint8(1) != magic1) {
      throw const FormatException('magic 不匹配');
    }
    if (data.getUint8(2) != version) {
      throw FormatException('不支持的版本: ${data.getUint8(2)}');
    }
    final flags = data.getUint8(3);
    final typeIndex = data.getUint8(4);
    if (typeIndex >= MessageType.values.length) {
      throw FormatException('未知消息类型: $typeIndex');
    }

    // 与 encode 相同：从 magic 起算的固定头部共 27 字节。
    var o = 4;
    final roomIdLength = data.getUint16(o + 1, Endian.big);
    final fromLength = data.getUint16(o + 3, Endian.big);
    final toLength = data.getUint16(o + 5, Endian.big);
    final seq = data.getUint32(o + 7, Endian.big);
    final lamport = data.getUint64(o + 11, Endian.big);
    final payloadLength = data.getUint32(o + 19, Endian.big);
    o += 23;

    if (o + roomIdLength + fromLength + toLength + payloadLength >
        bytes.length) {
      throw const FormatException('长度字段与实际数据不符');
    }
    final roomId = utf8.decode(bytes.sublist(o, o + roomIdLength));
    o += roomIdLength;
    final from = utf8.decode(bytes.sublist(o, o + fromLength));
    o += fromLength;
    final toRaw = utf8.decode(bytes.sublist(o, o + toLength));
    o += toLength;

    var payload = Uint8List.sublistView(bytes, o, o + payloadLength);
    if (flags & flagCompressed != 0) {
      payload = Uint8List.fromList(_zlib.decode(payload));
    }

    return Envelope(
      type: MessageType.values[typeIndex],
      roomId: roomId,
      from: from,
      to: toRaw.isEmpty ? null : toRaw,
      seq: seq,
      lamport: lamport,
      payload: payload,
    );
  }
}

/// 为信封帧加长度前缀，构成传输帧。
Uint8List frameEnvelope(Uint8List encoded) {
  final result = BytesBuilder(copy: false);
  final prefix = ByteData(4)..setUint32(0, encoded.length, Endian.big);
  result.add(prefix.buffer.asUint8List(0, 4));
  result.add(encoded);
  return result.toBytes();
}

/// 长度前缀帧拆包器：喂入字节流片段，吐出完整信封帧。
///
/// 可处理半包（一次喂半帧）与粘包（一次喂多帧）。
class FrameSplitter {
  FrameSplitter({this.maxFrameBytes = 8 * 1024 * 1024});

  final int maxFrameBytes;
  final BytesBuilder _pending = BytesBuilder(copy: true);

  /// 喂入一段字节，返回其中包含的完整帧。
  List<Uint8List> push(List<int> chunk) {
    _pending.add(chunk);
    final frames = <Uint8List>[];
    var bytes = _pending.toBytes();
    while (bytes.length >= 4) {
      final length = ByteData.sublistView(bytes).getUint32(0, Endian.big);
      if (length > maxFrameBytes) {
        throw FormatException('帧过大: $length > $maxFrameBytes');
      }
      if (bytes.length < 4 + length) break;
      frames.add(Uint8List.sublistView(bytes, 4, 4 + length));
      bytes = Uint8List.sublistView(bytes, 4 + length);
    }
    _pending.clear();
    if (bytes.isNotEmpty) _pending.add(bytes);
    return frames;
  }
}
