import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:taraxacum_draw/domain/envelope.dart';
import 'package:taraxacum_draw/infrastructure/transport/envelope_codec.dart';
import 'package:taraxacum_draw/infrastructure/transport/lan_transport.dart';
import 'package:taraxacum_draw/infrastructure/transport/transport.dart';

Envelope makeEnvelope(String from, {MessageType type = MessageType.op}) =>
    Envelope(
      type: type,
      roomId: 'room-x',
      from: from,
      seq: 1,
      lamport: 1,
      payload: Uint8List.fromList([9, 9, 9]),
    );

void main() {
  test('LAN 传输：本机回环 echo 往返 + joined/left 事件', () async {
    final host = LanTransport(selfPeer: 'host-1', enableMdns: false);
    await host.start(asHost: true, roomId: 'room-x');
    expect(host.boundPort, greaterThan(0));

    // 先订阅，再连接，避免广播流丢事件。
    final hostMessageFuture = host.messages.first.timeout(
      const Duration(seconds: 5),
      onTimeout: () => throw TimeoutException('host 未收到消息'),
    );
    final hostJoinedFuture = host.peerEvents.first.timeout(
      const Duration(seconds: 5),
      onTimeout: () => throw TimeoutException('host 未收到 joined'),
    );
    final hostLinkFuture = host.incomingLinks.first;

    final guest = LanTransport(selfPeer: 'guest-1', enableMdns: false);
    final guestLink =
        await guest.dial(LanEndpoint(host: '127.0.0.1', port: host.boundPort));
    expect(guestLink.isOpen, isTrue);

    // 成员 → 房主。
    await guestLink.send(makeEnvelope('guest-1'));

    final acceptedLink = await hostLinkFuture;
    final received = await hostMessageFuture;
    expect(received.from, 'guest-1');
    expect(received.type, MessageType.op);

    final joined = await hostJoinedFuture;
    expect(joined.peer, 'guest-1');
    expect(joined.kind, PeerEventKind.joined);

    // 房主 → 成员（echo 回复）。
    await acceptedLink.send(makeEnvelope('host-1', type: MessageType.pong));
    final echoed = await guestLink.messages.first.timeout(
      const Duration(seconds: 5),
      onTimeout: () => throw TimeoutException('guest 未收到 echo'),
    );
    expect(echoed.from, 'host-1');
    expect(echoed.type, MessageType.pong);
    expect(guestLink.remotePeer, 'host-1', reason: '对端身份来自首条信封');

    // 成员正常关闭 → 房主收到 left。
    await guestLink.close();
    final left = await host.peerEvents
        .firstWhere((e) => e.kind == PeerEventKind.left)
        .timeout(const Duration(seconds: 5));
    expect(left.peer, 'guest-1');

    await host.stop();
    expect(host.isRunning, isFalse);
  });

  test('LAN 传输：损坏帧触发 lost 事件', () async {
    final host = LanTransport(selfPeer: 'host-1', enableMdns: false);
    await host.start(asHost: true, roomId: 'room-x');

    final raw = await Socket.connect('127.0.0.1', host.boundPort);
    await host.incomingLinks.first;

    // 先以合法信封建立身份。
    raw.add(frameEnvelope(EnvelopeCodec.encode(makeEnvelope('bad-peer'))));
    final joined = await host.peerEvents.first.timeout(const Duration(seconds: 5));
    expect(joined.kind, PeerEventKind.joined);

    // 再发损坏帧（长度前缀超限）→ lost。
    final lostFuture = host.peerEvents
        .firstWhere((e) => e.kind == PeerEventKind.lost)
        .timeout(const Duration(seconds: 5));
    final evil = ByteData(4)..setUint32(0, 0x7FFFFFFF, Endian.big);
    raw.add(evil.buffer.asUint8List());

    final lost = await lostFuture;
    expect(lost.peer, 'bad-peer');
    expect(lost.kind, PeerEventKind.lost);

    raw.destroy();
    await host.stop();
  });

  test('LAN 传输：未启动时 stop 为安全空操作', () async {
    final transport = LanTransport(selfPeer: 'p', enableMdns: false);
    await transport.stop();
    expect(transport.isRunning, isFalse);
  });
}
