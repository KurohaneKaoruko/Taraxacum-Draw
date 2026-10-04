import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:taraxacum_draw/domain/envelope.dart';
import 'package:taraxacum_draw/infrastructure/transport/manual/invite_codec.dart';
import 'package:taraxacum_draw/infrastructure/transport/manual/manual_transport.dart';
import 'package:taraxacum_draw/infrastructure/transport/transport.dart';

Envelope makeEnvelope(String from) => Envelope(
      type: MessageType.op,
      roomId: 'room-m',
      from: from,
      seq: 1,
      lamport: 1,
      payload: Uint8List.fromList([7, 7, 7]),
    );

InvitePayload makePayload({String name = '蒲公英房间'}) => InvitePayload(
      version: 1,
      roomId: 'room-m',
      hostPeerId: 'host-peer-1',
      hostName: name,
      port: 45678,
      ips: ['192.168.1.10', '10.0.0.5'],
    );

void main() {
  group('邀请码编解码', () {
    test('roundtrip：载荷完整还原', () {
      final code = InviteCodec.encodeInvite(makePayload());
      final decoded = InviteCodec.decodeInvite(code);
      expect(decoded.roomId, 'room-m');
      expect(decoded.hostPeerId, 'host-peer-1');
      expect(decoded.hostName, '蒲公英房间');
      expect(decoded.port, 45678);
      expect(decoded.ips, ['192.168.1.10', '10.0.0.5']);
    });

    test('长内容自动分帧且可乱序重组', () {
      // 不可压缩的伪随机名称，确保超过单帧容量。
      final longName = List.generate(300, (i) => '房间$i号画友$i').join();
      final code = InviteCodec.encodeInvite(makePayload(name: longName));
      final frames = InviteCodec.toFrames(code);
      expect(frames.length, greaterThan(1), reason: '长内容应拆为多帧');

      final shuffled = [...frames]..shuffle();
      final rebuilt = InviteCodec.fromFrames(shuffled);
      expect(rebuilt, code);
    });

    test('帧不完整时报错，重复帧可去重', () {
      final longName = List.generate(300, (i) => '房间$i号画友$i').join();
      final payload = makePayload(name: longName);
      final frames = InviteCodec.toFrames(InviteCodec.encodeInvite(payload));
      expect(
        () => InviteCodec.fromFrames(frames.take(frames.length - 1)),
        throwsFormatException,
      );
      // 重复帧允许（重复扫描同一码）。
      final rebuilt = InviteCodec.fromFrames([...frames, ...frames.take(1)]);
      expect(rebuilt, InviteCodec.encodeInvite(payload));
    });

    test('非邀请帧被忽略，损坏帧报错', () {
      final frames = InviteCodec.toFrames(
        InviteCodec.encodeInvite(makePayload()),
      );
      expect(
        InviteCodec.fromFrames(['noise', ...frames]),
        InviteCodec.encodeInvite(makePayload()),
      );
      expect(
        () => InviteCodec.fromFrames(['TDI|a|b|xx']),
        throwsFormatException,
      );
    });

    test('应答码 roundtrip', () {
      final code = InviteCodec.encodeAnswer(
        const AnswerInfo(guestPeerId: 'guest-9', guestName: '画友乙'),
      );
      final decoded = InviteCodec.decodeAnswer(code);
      expect(decoded.guestPeerId, 'guest-9');
      expect(decoded.guestName, '画友乙');
    });
  });

  test('ManualTransport 全流程：邀请 → 导入 → 直连 → 应答确认', () async {
    final host = ManualTransport(selfPeer: 'host-1');
    await host.start(asHost: true, roomId: 'room-m');
    expect(host.mode, ConnectionMode.manual);

    // 房主生成邀请（测试显式给回环地址）。
    final invite = await host.createInvite(
      roomId: 'room-m',
      roomName: '手工房间',
      ips: ['127.0.0.1'],
    );

    // 成员端：模拟分帧导入（乱序）→ 解析 → 直连。
    final guest = ManualTransport(selfPeer: 'guest-1');
    final payload = guest.importInvite(invite.frames.reversed);
    expect(payload.roomId, 'room-m');
    expect(payload.hostPeerId, 'host-1');

    final acceptedFuture = host.accept();
    final joinedFuture = host.peerEvents.first.timeout(
      const Duration(seconds: 5),
      onTimeout: () => throw TimeoutException('host 未收到 joined'),
    );
    final link = await guest.dial(
      LanEndpoint(host: payload.ips.first, port: payload.port),
    );

    // echo 往返。
    final hostLink = await acceptedFuture;
    final gotFuture = host.messages.first.timeout(const Duration(seconds: 5));
    await link.send(makeEnvelope('guest-1'));
    final got = await gotFuture;
    expect(got.from, 'guest-1');
    await hostLink.send(makeEnvelope('host-1'));
    final echoed = await link.messages.first.timeout(const Duration(seconds: 5));
    expect(echoed.from, 'host-1');

    // 应答码：成员生成 → 房主解析确认身份。
    final answerCode = guest.createAnswerCode(guestName: '画友乙');
    final answer = host.importAnswerCode(answerCode);
    expect(answer.guestPeerId, 'guest-1');
    expect(answer.guestName, '画友乙');

    final joined = await joinedFuture;
    expect(joined.kind, PeerEventKind.joined);

    await guest.stop();
    await host.stop();
  });

  test('未启动时生成邀请报错', () async {
    final transport = ManualTransport(selfPeer: 'p');
    expect(
      () => transport.createInvite(roomId: 'r', roomName: 'n'),
      throwsStateError,
    );
  });
}
