import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:taraxacum_draw/domain/envelope.dart';
import 'package:taraxacum_draw/infrastructure/transport/envelope_codec.dart';
import 'package:taraxacum_draw/infrastructure/transport/lan_transport.dart';
import 'package:taraxacum_draw/infrastructure/transport/transport.dart';

Envelope makeEnvelope(String from, {String roomId = 'room-hb'}) => Envelope(
      type: MessageType.op,
      roomId: roomId,
      from: from,
      seq: 1,
      lamport: 1,
      payload: Uint8List.fromList([1]),
    );

void main() {
  test('静默超时（崩溃/断网无 FIN）判定为 lost', () async {
    final host = LanTransport(
      selfPeer: 'host-1',
      enableMdns: false,
      heartbeatInterval: const Duration(milliseconds: 40),
      heartbeatTimeout: const Duration(milliseconds: 150),
    );
    await host.start(asHost: true, roomId: 'room-hb');
    // ignore: avoid_print
    print('STEP host started');

    final acceptedFuture = host.accept();
    final raw = await Socket.connect('127.0.0.1', host.boundPort);
    // ignore: avoid_print
    print('STEP raw connected');
    await acceptedFuture;
    // ignore: avoid_print
    print('STEP accepted');

    // 合法信封建立身份（joined），随后保持沉默。
    raw.add(frameEnvelope(EnvelopeCodec.encode(makeEnvelope('silent-peer'))));
    final joined = await host.peerEvents.first.timeout(const Duration(seconds: 5));
    expect(joined.kind, PeerEventKind.joined);
    // ignore: avoid_print
    print('STEP joined');

    final lost = await host.peerEvents
        .firstWhere((e) => e.kind == PeerEventKind.lost)
        .timeout(const Duration(seconds: 5), onTimeout: () {
      throw TimeoutException('静默掉线未被心跳判定为 lost');
    });
    expect(lost.peer, 'silent-peer');
    // ignore: avoid_print
    print('STEP lost ok');

    raw.destroy();
    // ignore: avoid_print
    print('STEP raw destroyed');
    await host.stop();
    // ignore: avoid_print
    print('STEP host stopped');
  });

  test('自动 pong 保活：活跃链路不误判为 lost', () async {
    final host = LanTransport(
      selfPeer: 'host-1',
      enableMdns: false,
      heartbeatInterval: const Duration(milliseconds: 50),
      heartbeatTimeout: const Duration(milliseconds: 500),
    );
    final guest = LanTransport(
      selfPeer: 'guest-1',
      enableMdns: false,
      heartbeatInterval: const Duration(milliseconds: 50),
      heartbeatTimeout: const Duration(milliseconds: 500),
    );
    await host.start(asHost: true, roomId: 'room-hb');

    final log = <String>[];
    final start = DateTime.now();
    String at() => '${DateTime.now().difference(start).inMilliseconds}ms';
    host.peerEvents.listen((e) => log.add('${at()} host ${e.peer} ${e.kind}'));
    guest.peerEvents.listen((e) => log.add('${at()} guest ${e.peer} ${e.kind}'));
    host.messages.listen((m) => log.add('${at()} host<-${m.from} ${m.type}'));
    guest.messages.listen((m) => log.add('${at()} guest<-${m.from} ${m.type}'));

    var sawLost = false;
    final lostSub = host.peerEvents.listen((e) {
      if (e.kind == PeerEventKind.lost) sawLost = true;
    });

    final guestLink =
        await guest.dial(LanEndpoint(host: '127.0.0.1', port: host.boundPort));
    await guestLink.send(makeEnvelope('guest-1'));
    await host.peerEvents.first.timeout(const Duration(seconds: 5));

    // 静置 600ms（> 2 倍超时），期间双方心跳 ping/pong 自动保活。
    await Future<void>.delayed(const Duration(milliseconds: 600));
    // ignore: avoid_print
    print('EVENTS:\n${log.join('\n')}');
    expect(sawLost, isFalse, reason: '活跃链路不应被判为 lost');
    expect(guestLink.isOpen, isTrue);

    // 收尾：干净退出 → left。
    await guestLink.close();
    // ignore: avoid_print
    print('STEP close done');
    final left = await host.peerEvents
        .firstWhere((e) => e.kind == PeerEventKind.left)
        .timeout(const Duration(seconds: 5));
    expect(left.kind, PeerEventKind.left);
    // ignore: avoid_print
    print('STEP left received');

    await lostSub.cancel();
    // ignore: avoid_print
    print('STEP lostSub cancelled');
    await host.stop();
    // ignore: avoid_print
    print('STEP host stopped');
    await guest.stop();
    // ignore: avoid_print
    print('STEP guest stopped');
  });
}
