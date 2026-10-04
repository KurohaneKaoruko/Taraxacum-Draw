import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taraxacum_draw/application/presence/presence_controller.dart';
import 'package:taraxacum_draw/domain/envelope.dart';
import 'package:taraxacum_draw/domain/ids.dart';
import 'package:taraxacum_draw/infrastructure/transport/transport.dart';

class CapturingTransport extends Transport {
  CapturingTransport({required String peer}) : super(selfPeer: peer);

  final List<Envelope> sent = [];
  final StreamController<Envelope> _messages =
      StreamController<Envelope>.broadcast();

  void receive(Envelope envelope) => _messages.add(envelope);

  @override
  ConnectionMode get mode => ConnectionMode.lan;

  @override
  Future<PeerLink> dial(Object endpoint) => throw UnimplementedError();

  @override
  Stream<Envelope> get messages => _messages.stream;

  @override
  Future<void> broadcast(Envelope envelope) async => sent.add(envelope);

  @override
  Future<bool> sendTo(Envelope envelope, PeerId peer) async {
    sent.add(envelope);
    return true;
  }
}

PresenceController wiredController(CapturingTransport transport) {
  final container = ProviderContainer();
  final controller = container.read(presenceProvider.notifier)
    ..configure(selfPeerId: 'self', roomId: 'room-p')
    ..bind([transport]);
  return controller;
}

Envelope chatEnvelope(String from, {String text = '你好', String to = ''}) =>
    Envelope(
      type: MessageType.chat,
      roomId: 'room-p',
      from: from,
      to: to.isEmpty ? null : to,
      seq: 1,
      lamport: 1,
      payload: Uint8List.fromList(utf8.encode(
          '{"t":"$text","n":"远端成员","c":4294901760,"ms":1700000000000}')),
    );

void main() {
  test('光标发送节流：高频移动被限制在 ~30Hz', () async {
    final transport = CapturingTransport(peer: 'self');
    final controller = wiredController(transport);

    for (var i = 0; i < 100; i++) {
      controller.onLocalPointer(
        selfPeerId: 'self',
        selfName: '我',
        selfColor: 1,
        x: i.toDouble(),
        y: 0,
      );
    }
    final immediate = transport.sent.where((e) => e.type == MessageType.cursor);
    expect(immediate.length, lessThanOrEqualTo(3), reason: '33ms 节流上限');

    await Future<void>.delayed(const Duration(milliseconds: 40));
    controller.onLocalPointer(
      selfPeerId: 'self',
      selfName: '我',
      selfColor: 1,
      x: 99,
      y: 0,
    );
    final after = transport.sent.where((e) => e.type == MessageType.cursor);
    expect(after.length, greaterThan(1), reason: '40ms 后应允许再次发送');
  });

  test('远端光标信封更新状态；移除成员清理光标', () async {
    final transport = CapturingTransport(peer: 'self');
    final controller = wiredController(transport);

    transport.receive(Envelope(
      type: MessageType.cursor,
      roomId: 'room-p',
      from: 'peer-b',
      seq: 1,
      lamport: 1,
      payload: Uint8List.fromList(
          utf8.encode('{"x":12.5,"y":30,"n":"画友乙","c":4294901760}')),
    ));
    await Future<void>.delayed(Duration.zero);

    expect(controller.state.cursors['peer-b']?.x, 12.5);
    expect(controller.state.cursors['peer-b']?.name, '画友乙');

    controller.removePeer('peer-b');
    expect(controller.state.cursors.containsKey('peer-b'), isFalse);
  });

  test('聊天：本地发送立即入列并广播；远端消息入列', () async {
    final transport = CapturingTransport(peer: 'self');
    final controller = wiredController(transport);

    controller.sendChat(
      selfPeerId: 'self',
      selfName: '我',
      selfColor: 1,
      text: '  大家好  ',
    );
    expect(controller.state.messages.single.text, '大家好', reason: '首尾空白应去除');
    expect(
      transport.sent
          .where((e) => e.type == MessageType.chat)
          .map((e) => utf8.decode(e.payload))
          .single,
      contains('大家好'),
    );

    transport.receive(chatEnvelope('peer-b'));
    await Future<void>.delayed(Duration.zero);
    expect(controller.state.messages.length, 2);
    final remote = controller.state.messages.last;
    expect(remote.peerId, 'peer-b');
    expect(remote.text, '你好');
    expect(remote.name, '远端成员');
  });

  test('开关：显示他人光标默认开且可切换', () {
    final transport = CapturingTransport(peer: 'self');
    final controller = wiredController(transport);

    expect(controller.state.showRemoteCursors, isTrue);
    controller.toggleRemoteCursors();
    expect(controller.state.showRemoteCursors, isFalse);
    controller.toggleRemoteCursors();
    expect(controller.state.showRemoteCursors, isTrue);
  });

  test('解绑后不再接收消息', () async {
    final transport = CapturingTransport(peer: 'self');
    final container = ProviderContainer();
    final controller = container.read(presenceProvider.notifier)
      ..configure(selfPeerId: 'self', roomId: 'room-p')
      ..bind([transport]);
    controller.unbind();

    transport.receive(chatEnvelope('peer-b'));
    await Future<void>.delayed(Duration.zero);
    expect(controller.state.messages, isEmpty, reason: '解绑后不应收到消息');
    container.dispose();
  });
}
