import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:taraxacum_draw/domain/envelope.dart';
import 'package:taraxacum_draw/infrastructure/transport/signaling/signaling.dart';
import 'package:taraxacum_draw/infrastructure/transport/signaling/signaling_crypto.dart';
import 'package:taraxacum_draw/infrastructure/transport/transport.dart';
import 'package:taraxacum_draw/infrastructure/transport/webrtc/webrtc_transport.dart';

import 'fake_webrtc.dart';

Envelope makeEnvelope(String from, {MessageType type = MessageType.op}) =>
    Envelope(
      type: type,
      roomId: 'room-w',
      from: from,
      seq: 1,
      lamport: 1,
      payload: Uint8List.fromList([5, 5, 5]),
    );

void main() {
  test('信令载荷加密：roundtrip 与错误密钥失败', () async {
    final crypto = await SignalingCrypto.create(roomId: 'room-w', roomKey: 'key123');
    final sealed = await crypto.encrypt('秘密 SDP 内容');
    expect(sealed, isNot(encodeUtf8('秘密 SDP 内容')), reason: '载荷应为密文');
    expect(await crypto.decrypt(sealed), '秘密 SDP 内容');

    final wrong = await SignalingCrypto.create(roomId: 'room-w', roomKey: 'wrong');
    expect(
      () => wrong.decrypt(sealed),
      throwsA(anything),
      reason: '错误房间密钥必须解密失败',
    );
  });

  test('信令主题：同房间同密钥一致，不同密钥不同', () async {
    expect(
      await signalingTopic('room-w', 'key123'),
      await signalingTopic('room-w', 'key123'),
    );
    expect(
      await signalingTopic('room-w', 'key123'),
      isNot(await signalingTopic('room-w', 'other')),
    );
    expect(
      await signalingTopic('room-w', 'key123'),
      isNot(await signalingTopic('room-x', 'key123')),
    );
  });

  test('WebRTC 传输全流程：join→offer→answer→echo→close→left', () async {
    final bus = InMemorySignalingBus();
    final network = FakeWebRtcNetwork();

    final host = WebRtcTransport(
      selfPeer: 'host-1',
      signaling: bus.attach('host-1'),
      connectionFactory: network.create,
    );
    final guest = WebRtcTransport(
      selfPeer: 'guest-1',
      signaling: bus.attach('guest-1'),
      connectionFactory: network.create,
    );

    final hostMessages = <Envelope>[];
    host.messages.listen(hostMessages.add);
    final joinedFuture = host.peerEvents.first.timeout(
      const Duration(seconds: 5),
      onTimeout: () => throw TimeoutException('host 未收到 joined'),
    );
    final acceptedFuture = host.accept();
    final hostLeftFuture = host.peerEvents
        .firstWhere((e) => e.kind == PeerEventKind.left)
        .timeout(const Duration(seconds: 5));

    await host.start(asHost: true, roomId: 'room-w', roomKey: 'key123');

    final guestLink = await guest
        .dial(WebRtcEndpoint(roomId: 'room-w', roomKey: 'key123'))
        .timeout(
          const Duration(seconds: 5),
          onTimeout: () => throw TimeoutException('加入流程超时'),
        );
    expect(guestLink.isOpen, isTrue);
    expect(guestLink.remotePeer, 'host-1');

    final joined = await joinedFuture;
    expect(joined.peer, 'guest-1');
    expect(joined.kind, PeerEventKind.joined);

    // 成员 → 房主。
    await guestLink.send(makeEnvelope('guest-1'));
    final hostGot = await host.messages
        .firstWhere((m) => m.type == MessageType.op)
        .timeout(
          const Duration(seconds: 5),
          onTimeout: () => throw TimeoutException('host 未收到成员消息'),
        );
    expect(hostGot.from, 'guest-1');

    // 房主 → 成员（经 accept 拿到房主侧链路）。
    final hostLink = await acceptedFuture;
    expect(hostLink.remotePeer, 'guest-1');
    await hostLink.send(makeEnvelope('host-1', type: MessageType.pong));
    final guestGot = await guestLink.messages
        .firstWhere((m) => m.type == MessageType.pong)
        .timeout(
          const Duration(seconds: 5),
          onTimeout: () => throw TimeoutException('guest 未收到房主消息'),
        );
    expect(guestGot.from, 'host-1');
    expect(guestGot.type, MessageType.pong);

    // 大 payload（压缩路径）双向。
    final bigPayload = List.generate(1024, (i) => i % 3);
    await guestLink.send(makeEnvelope('guest-1').copyPayload(bigPayload));
    final bigGot = await host.messages
        .firstWhere((m) => m.type == MessageType.op && m.payload.length == 1024)
        .timeout(const Duration(seconds: 5));
    expect(bigGot.payload.length, 1024);

    // 成员关闭 → 房主 left。
    await guestLink.close();
    final left = await hostLeftFuture;
    expect(left.peer, 'guest-1');

    await host.stop();
    await guest.stop();
  });
}

extension on Envelope {
  // 仅测试辅助：替换 payload 的浅拷贝。
  Envelope copyPayload(List<int> payload) => Envelope(
        type: type,
        roomId: roomId,
        from: from,
        seq: seq,
        lamport: lamport,
        payload: Uint8List.fromList(payload),
      );
}

Uint8List encodeUtf8(String s) => Uint8List.fromList(s.codeUnits);
