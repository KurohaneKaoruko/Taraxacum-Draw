import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:taraxacum_draw/domain/envelope.dart';
import 'package:taraxacum_draw/domain/ids.dart';
import 'package:taraxacum_draw/infrastructure/transport/transport.dart';
import 'package:taraxacum_draw/infrastructure/transport/transport_selector.dart';

PeerLink fakeLink() => _FakeLink();

class _FakeLink extends PeerLink {
  @override
  PeerId get remotePeer => 'remote';

  @override
  bool get isOpen => true;

  @override
  Stream<Envelope> get messages => const Stream.empty();

  @override
  Future<void> send(Envelope message) async {}

  @override
  Future<PeerEventKind> get closed => Completer<PeerEventKind>().future;

  @override
  Future<void> close([PeerEventKind reason = PeerEventKind.left]) async {}
}

void main() {
  test('第一优先级成功：后续方式不被触碰', () async {
    final calls = <ConnectionMode>[];
    final selector = TransportSelector(autoAttempts: [
      AutoJoinAttempt(mode: ConnectionMode.lan, attempt: () async {
        calls.add(ConnectionMode.lan);
        return fakeLink();
      }),
      AutoJoinAttempt(mode: ConnectionMode.webrtc, attempt: () async {
        calls.add(ConnectionMode.webrtc);
        throw StateError('不应被调用');
      }),
    ]);

    final result = await selector.selectAndJoin();
    expect(result, isA<AutoJoined>());
    expect((result as AutoJoined).mode, ConnectionMode.lan);
    expect(calls, [ConnectionMode.lan], reason: 'LAN 成功后不得尝试 WebRTC');
  });

  test('LAN 超时降级 WebRTC：顺序正确且超时生效', () async {
    final calls = <ConnectionMode>[];
    final selector = TransportSelector(
      autoAttempts: [
        AutoJoinAttempt(mode: ConnectionMode.lan, attempt: () async {
          calls.add(ConnectionMode.lan);
          await Future<void>.delayed(const Duration(seconds: 30));
          throw StateError('unreachable');
        }),
        AutoJoinAttempt(mode: ConnectionMode.webrtc, attempt: () async {
          calls.add(ConnectionMode.webrtc);
          return fakeLink();
        }),
      ],
      perAttemptTimeout: const Duration(milliseconds: 100),
    );

    final sw = Stopwatch()..start();
    final result = await selector.selectAndJoin();
    sw.stop();

    expect(result, isA<AutoJoined>());
    expect((result as AutoJoined).mode, ConnectionMode.webrtc);
    expect(calls, [ConnectionMode.lan, ConnectionMode.webrtc]);
    expect(sw.elapsedMilliseconds, lessThan(5000),
        reason: 'LAN 尝试应被 100ms 硬超时截断');
  });

  test('全部自动方式失败：进入手动流程并携带失败原因', () async {
    final selector = TransportSelector(autoAttempts: [
      AutoJoinAttempt(mode: ConnectionMode.lan, attempt: () async {
        throw StateError('未发现房间');
      }),
      AutoJoinAttempt(mode: ConnectionMode.webrtc, attempt: () async {
        throw StateError('信令不可达');
      }),
    ]);

    final result = await selector.selectAndJoin();
    expect(result, isA<NeedsManual>());
    final manual = result as NeedsManual;
    expect(manual.errors[ConnectionMode.lan], contains('未发现房间'));
    expect(manual.errors[ConnectionMode.webrtc], contains('信令不可达'));
  });

  test('手动不可用时全部失败返回 JoinFailed', () async {
    final selector = TransportSelector(
      autoAttempts: [
        AutoJoinAttempt(mode: ConnectionMode.lan, attempt: () async {
          throw StateError('x');
        }),
      ],
      manualAvailable: false,
    );

    final result = await selector.selectAndJoin();
    expect(result, isA<JoinFailed>());
  });
}
