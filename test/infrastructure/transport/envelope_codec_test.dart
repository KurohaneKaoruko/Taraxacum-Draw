import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:taraxacum_draw/domain/envelope.dart';
import 'package:taraxacum_draw/infrastructure/transport/envelope_codec.dart';

Envelope makeEnvelope({
  MessageType type = MessageType.op,
  String roomId = 'room-1',
  String from = 'peer-a',
  int seq = 7,
  int lamport = 42,
  List<int> payload = const [1, 2, 3],
}) =>
    Envelope(
      type: type,
      roomId: roomId,
      from: from,
      seq: seq,
      lamport: lamport,
      payload: Uint8List.fromList(payload),
    );

void main() {
  group('EnvelopeCodec roundtrip', () {
    test('小 payload 原样往返', () {
      final original = makeEnvelope();
      final decoded = EnvelopeCodec.decode(EnvelopeCodec.encode(original));
      expect(decoded.type, original.type);
      expect(decoded.roomId, original.roomId);
      expect(decoded.from, original.from);
      expect(decoded.seq, original.seq);
      expect(decoded.lamport, original.lamport);
      expect(decoded.payload, original.payload);
    });

    test('全部消息类型可往返', () {
      for (final type in MessageType.values) {
        final decoded = EnvelopeCodec.decode(
          EnvelopeCodec.encode(makeEnvelope(type: type)),
        );
        expect(decoded.type, type);
      }
    });

    test('大 payload 启用压缩且正确还原', () {
      final bigPayload = List.generate(4096, (i) => i % 4); // 高度可压缩
      final original = makeEnvelope(payload: bigPayload);

      final encoded = EnvelopeCodec.encode(original);
      expect(encoded.length, lessThan(4096 + 64), reason: '压缩应显著缩小体积');

      final decoded = EnvelopeCodec.decode(encoded);
      expect(decoded.payload, bigPayload);
    });

    test('不可压缩 payload 仍可往返', () {
      final randomPayload =
          List.generate(512, (i) => (i * 7919 + 13) % 256);
      final decoded = EnvelopeCodec.decode(
        EnvelopeCodec.encode(makeEnvelope(payload: randomPayload)),
      );
      expect(decoded.payload, randomPayload);
    });

    test('中文 roomId/from 按 utf8 往返', () {
      final decoded = EnvelopeCodec.decode(
        EnvelopeCodec.encode(
          makeEnvelope(roomId: '房间-蒲公英', from: '画友-甲'),
        ),
      );
      expect(decoded.roomId, '房间-蒲公英');
      expect(decoded.from, '画友-甲');
    });
  });

  group('损坏包', () {
    test('magic 错误报 FormatException', () {
      final encoded = EnvelopeCodec.encode(makeEnvelope());
      encoded[0] = 0x00;
      expect(() => EnvelopeCodec.decode(encoded), throwsFormatException);
    });

    test('版本错误报 FormatException', () {
      final encoded = EnvelopeCodec.encode(makeEnvelope());
      encoded[2] = 0xFF;
      expect(() => EnvelopeCodec.decode(encoded), throwsFormatException);
    });

    test('未知消息类型报 FormatException', () {
      final encoded = EnvelopeCodec.encode(makeEnvelope());
      encoded[4] = 0x7F;
      expect(() => EnvelopeCodec.decode(encoded), throwsFormatException);
    });

    test('截断帧报 FormatException', () {
      final encoded = EnvelopeCodec.encode(makeEnvelope());
      expect(
        () => EnvelopeCodec.decode(encoded.sublist(0, encoded.length - 2)),
        throwsFormatException,
      );
    });

    test('长度字段被篡改报 FormatException', () {
      final encoded = EnvelopeCodec.encode(makeEnvelope());
      // payloadLen 位于头部偏移 26（2+1+1+1+2+6+2+6+4+8）。
      final tampered = Uint8List.fromList(encoded);
      ByteData.sublistView(tampered).setUint32(26, 0xFFFFFF, Endian.big);
      expect(() => EnvelopeCodec.decode(tampered), throwsFormatException);
    });
  });

  group('FrameSplitter 长度前缀帧', () {
    test('frameEnvelope 与拆包器互逆', () {
      final payload = EnvelopeCodec.encode(makeEnvelope());
      final frames = FrameSplitter().push(frameEnvelope(payload));
      expect(frames.single, payload);
    });

    test('粘包：多帧一次到达全部拆出', () {
      final splitter = FrameSplitter();
      final a = frameEnvelope(Uint8List.fromList([1, 1, 1]));
      final b = frameEnvelope(Uint8List.fromList([2, 2]));
      final c = frameEnvelope(Uint8List.fromList([3]));
      final frames = splitter.push([...a, ...b, ...c]);
      expect(frames.length, 3);
      expect(frames[0], a.sublist(4));
      expect(frames[1], b.sublist(4));
      expect(frames[2], c.sublist(4));
    });

    test('半包：分片到达最终拆出', () {
      final splitter = FrameSplitter();
      final whole = frameEnvelope(EnvelopeCodec.encode(makeEnvelope()));
      expect(splitter.push(whole.sublist(0, 3)), isEmpty);
      expect(splitter.push(whole.sublist(3, 10)), isEmpty);
      final frames = splitter.push(whole.sublist(10));
      expect(frames.single, whole.sublist(4));
    });

    test('超长帧报 FormatException', () {
      final splitter = FrameSplitter(maxFrameBytes: 16);
      final evil = ByteData(4)..setUint32(0, 4096, Endian.big);
      expect(
        () => splitter.push(evil.buffer.asUint8List()),
        throwsFormatException,
      );
    });
  });
}
