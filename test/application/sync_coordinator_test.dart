import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taraxacum_draw/application/canvas_controller.dart';
import 'package:taraxacum_draw/application/sync/sync_coordinator.dart';
import 'package:taraxacum_draw/domain/canvas_document.dart';
import 'package:taraxacum_draw/domain/envelope.dart';
import 'package:taraxacum_draw/domain/ids.dart';
import 'package:taraxacum_draw/domain/layer.dart';
import 'package:taraxacum_draw/domain/op.dart';
import 'package:taraxacum_draw/domain/op_codec.dart';
import 'package:taraxacum_draw/domain/stroke.dart';
import 'package:taraxacum_draw/infrastructure/transport/transport.dart';

/// 内存网状总线：广播投递给其他所有客户端（可注入丢包过滤器）。
class FakeMeshBus {
  final List<FakeMeshTransport> clients = [];
  final List<Envelope> delivered = [];

  /// 返回 true 表示丢弃该包（模拟丢包）。
  bool Function(FakeMeshTransport from, FakeMeshTransport to, Envelope e)?
      dropFilter;

  void deliver(FakeMeshTransport from, Envelope e) {
    for (final client in clients) {
      if (client.selfPeer == from.selfPeer) continue;
      if (e.to != null && client.selfPeer != e.to) continue;
      if (dropFilter != null && dropFilter!(from, client, e)) continue;
      delivered.add(e);
      scheduleMicrotask(() => client.receive(e));
    }
  }
}

class FakeMeshTransport extends Transport {
  FakeMeshTransport({required String peer, required this.bus})
      : super(selfPeer: peer) {
    bus.clients.add(this);
  }

  final FakeMeshBus bus;
  final StreamController<Envelope> _messages =
      StreamController<Envelope>.broadcast();

  void receive(Envelope envelope) => _messages.add(envelope);

  @override
  ConnectionMode get mode => ConnectionMode.lan;

  @override
  bool get isRunning => true;

  @override
  Future<void> start({required bool asHost, required RoomId roomId}) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<PeerLink> dial(Object endpoint) => throw UnimplementedError();

  @override
  Stream<Envelope> get messages => _messages.stream;

  @override
  Future<void> broadcast(Envelope envelope) async => bus.deliver(this, envelope);

  @override
  Future<bool> sendTo(Envelope envelope, PeerId peer) async {
    bus.delivered.add(envelope);
    scheduleMicrotask(() {
      for (final client in bus.clients) {
        if (client.selfPeer == peer) client.receive(envelope);
      }
    });
    return true;
  }
}

/// 三人房间测试装置。
class Fixture {
  Fixture(this.roomId, {this.snapshotThreshold = 2000}) {
    for (final peer in ['a', 'b', 'c']) {
      final container = ProviderContainer();
      containers.add(container);
      final canvas = container.read(canvasProvider.notifier)..authorId = peer;
      canvases.add(canvas);
      final transport = FakeMeshTransport(peer: peer, bus: bus);
      transports.add(transport);
      final coordinator = SyncCoordinator(
        selfPeerId: peer,
        canvas: canvas,
        roomId: roomId,
        snapshotThreshold: snapshotThreshold,
      );
      coordinator.bind([transport]);
      canvas.onLocalOp = coordinator.broadcastLocalOp;
      coordinators.add(coordinator);
    }
  }

  final int snapshotThreshold;

  final FakeMeshBus bus = FakeMeshBus();
  final List<ProviderContainer> containers = [];
  final List<CanvasController> canvases = [];
  final List<FakeMeshTransport> transports = [];
  final List<SyncCoordinator> coordinators = [];
  final String roomId;

  void draw(int peerIndex, double x) {
    final canvas = canvases[peerIndex];
    canvas
      ..onPointerDown(x, 0, null)
      ..onPointerMove(x + 40, 30, null)
      ..onPointerMove(x + 80, 60, null)
      ..onPointerUp();
  }

  Future<void> pump() => Future<void>.delayed(const Duration(milliseconds: 10));

  void dispose() {
    for (final c in coordinators) {
      c.dispose();
    }
    for (final c in containers) {
      c.dispose();
    }
  }
}

void main() {
  test('OpCodec：全部 kind roundtrip（含空压力点与中文）', () {
    final strokeOp = AddStrokeOp(
      opId: 'o1',
      authorId: '画友甲',
      lamport: 42,
      wallTimeMs: 12345,
      stroke: Stroke(
        id: 's1',
        authorId: '画友甲',
        layerId: '图层-1',
        tool: DrawTool.eraser,
        color: 0x80FF00AA,
        width: 7.5,
        points: const [
          StrokePoint(x: 1.5, y: -2.5),
          StrokePoint(x: 3.25, y: 8.125, pressure: 0.75),
        ],
        createdAtMs: 12345,
      ),
    );
    final decodedStroke = OpCodec.decode(OpCodec.encode(strokeOp)) as AddStrokeOp;
    expect(decodedStroke.stroke.id, 's1');
    expect(decodedStroke.stroke.layerId, '图层-1');
    expect(decodedStroke.stroke.tool, DrawTool.eraser);
    expect(decodedStroke.stroke.color, 0x80FF00AA);
    expect(decodedStroke.stroke.width, 7.5);
    expect(decodedStroke.stroke.points.length, 2);
    expect(decodedStroke.stroke.points[1].pressure, 0.75);

    final layer = _layer('l1', '天空', 3, false);
    expect(
      (OpCodec.decode(OpCodec.encode(AddLayerOp(
        opId: 'o2',
        authorId: 'a',
        lamport: 1,
        wallTimeMs: 0,
        layer: layer,
      ))) as AddLayerOp)
          .layer
          .name,
      '天空',
    );
    expect(
      (OpCodec.decode(OpCodec.encode(UndoOp(
        opId: 'u1',
        authorId: 'a',
        lamport: 2,
        wallTimeMs: 0,
        undoneOpId: 'o1',
      ))) as UndoOp)
          .undoneOpId,
      'o1',
    );
  });

  test('5.1/5.5 双人互画 + 撤销同步', () async {
    final f = Fixture('room-sync')..draw(0, 10); // A 画一笔
    await f.pump();

    // A 的笔画到达 B/C。
    expect(f.canvases[1].document.strokesOf('base').length, 1);
    expect(f.canvases[2].document.strokesOf('base').length, 1);
    final strokeId = f.canvases[0].document.strokesOf('base').first.id;

    // B 画一笔 → A/C 可见。
    f.draw(1, 100);
    await f.pump();
    expect(f.canvases[0].document.strokesOf('base').length, 2);

    // A 撤销自己那笔 → B/C 同步移除，B 的笔画保留。
    f.containers[0].read(canvasProvider.notifier).undo();
    await f.pump();
    expect(f.canvases[0].document.strokesOf('base').length, 1);
    expect(f.canvases[1].document.strokesOf('base').length, 1);
    expect(f.canvases[2].document.strokesOf('base').length, 1);
    expect(
      f.canvases[1].document.strokesOf('base').first.id,
      isNot(strokeId),
      reason: '保留的应是 B 的笔画',
    );

    f.dispose();
  });

  test('5.1 丢包注入：缺口检测 + 重传补齐', () async {
    final f = Fixture('room-loss');
    var dropped = false;
    f.bus.dropFilter = (from, to, e) {
      if (!dropped && from.selfPeer == 'a' && e.type == MessageType.op && e.seq == 2) {
        dropped = true;
        return true;
      }
      return false;
    };

    for (var i = 0; i < 4; i++) {
      f.draw(0, i * 100.0);
    }
    await f.pump();
    await f.pump();

    expect(f.canvases[1].document.strokesOf('base').length, 4,
        reason: '丢失的 op 应经重传请求补齐');
    f.dispose();
  });

  test('5.2 收敛：乱序 + 重复注入后各端重放一致', () async {
    final f = Fixture('room-conv');
    // 三端各画三笔（本地即时入账 + 广播）。
    for (var p = 0; p < 3; p++) {
      for (var i = 0; i < 3; i++) {
        f.draw(p, (p * 10 + i) * 50.0);
      }
    }
    await f.pump();

    // 取总线上的全部 op 信封，乱序 + 每条重复两次。
    final opEnvelopes =
        f.bus.delivered.where((e) => e.type == MessageType.op).toList();
    final replay = [...opEnvelopes, ...opEnvelopes]..shuffle();

    // 全新对等端集合重放。
    final replayBus = FakeMeshBus();
    final docs = <CanvasDocument>[];
    final containers = <ProviderContainer>[];
    for (final peer in ['r1', 'r2', 'r3']) {
      final container = ProviderContainer();
      containers.add(container);
      final canvas = container.read(canvasProvider.notifier)..authorId = peer;
      docs.add(canvas.document);
      final transport = FakeMeshTransport(peer: peer, bus: replayBus);
      final coordinator = SyncCoordinator(
        selfPeerId: peer,
        canvas: canvas,
        roomId: 'room-conv',
      );
      coordinator.bind([transport]);
      for (final envelope in replay) {
        coordinator.handleEnvelope(envelope);
      }
    }

    final reference = [
      for (final s in f.canvases[0].document.strokesOf('base')) s.id,
    ]..sort();
    for (final doc in docs) {
      final ids = [
        for (final s in doc.strokesOf('base')) s.id,
      ]..sort();
      expect(ids, reference, reason: '乱序+重复注入必须收敛到相同状态');
    }
    for (final c in containers) {
      c.dispose();
    }
    f.dispose();
  });

  test('5.3 中途加入补齐：全量日志分片 + 进度', () async {
    final f = Fixture('room-catchup')..draw(0, 10);
    f.draw(0, 200);
    await f.pump();

    // 新成员 d：空画布加入。
    final container = ProviderContainer();
    final canvasD = container.read(canvasProvider.notifier)..authorId = 'd';
    final transportD = FakeMeshTransport(peer: 'd', bus: f.bus);
    final progress = <double?>[];
    final coordinator = SyncCoordinator(
      selfPeerId: 'd',
      canvas: canvasD,
      roomId: 'room-catchup',
    );
    coordinator.catchUpProgress.addListener(() {
      progress.add(coordinator.catchUpProgress.value);
    });
    coordinator.bind([transportD]);

    await f.coordinators[0].sendOpLogTo('d');
    await f.pump();

    expect(
      canvasD.document.strokesOf('base').length,
      f.canvases[0].document.strokesOf('base').length,
      reason: '新成员应获得全部历史笔画',
    );
    expect(progress.isNotEmpty, isTrue);
    expect(progress.last, null, reason: '补齐完成后进度归位');
    container.dispose();
    f.dispose();
  });

  test('5.6 快照补齐：超阈值改发快照（不泄露撤销语义）', () async {
    final f = Fixture('room-snap', snapshotThreshold: 10)..draw(0, 10);
    for (var i = 0; i < 12; i++) {
      f.draw(0, i * 30.0);
    }
    f.containers[0].read(canvasProvider.notifier).undo(); // 撤销最后一笔
    await f.pump();

    final container = ProviderContainer();
    final canvasD = container.read(canvasProvider.notifier)..authorId = 'd';
    final transportD = FakeMeshTransport(peer: 'd', bus: f.bus);
    final coordinator = SyncCoordinator(
      selfPeerId: 'd',
      canvas: canvasD,
      roomId: 'room-snap',
      snapshotThreshold: 10, // 12 条 op > 10 → 走快照
    );
    coordinator.bind([transportD]);
    await f.coordinators[0].sendOpLogTo('d');
    await f.pump();

    final hostIds = [
      for (final s in f.canvases[0].document.strokesOf('base')) s.id,
    ]..sort();
    final guestIds = [
      for (final s in canvasD.document.strokesOf('base')) s.id,
    ]..sort();
    expect(guestIds, hostIds, reason: '快照应还原当前可见内容（含撤销效果）');

    expect(f.coordinators[0].snapshotThreshold, 10);
    expect(f.canvases[0].document.log.length, greaterThan(10));
    final syncEnvs = f.bus.delivered
        .where((e) => e.type == MessageType.sync && e.to == 'd')
        .toList();
    expect(
      syncEnvs.any((e) => utf8.decode(e.payload).contains('"rt":"snap"')),
      isTrue,
      reason: '超阈值必须走快照路径',
    );
    expect(
      syncEnvs.any((e) => utf8.decode(e.payload).contains('"rt":"ops"')),
      isFalse,
      reason: '超阈值不得发送全量日志',
    );

    // 信令层断言：定向到 d 的 sync 信封走 snap，且没有任何 ops 分片。：定向到 d 的 sync 信封走 snap，且没有任何 ops 分片。
    final syncToD = f.bus.delivered.where(
      (e) => e.type == MessageType.sync && e.to == 'd',
    );
    expect(
      syncToD.any((e) => utf8.decode(e.payload).contains('"rt":"snap"')),
      isTrue,
    );
    expect(
      syncToD.any((e) => utf8.decode(e.payload).contains('"rt":"ops"')),
      isFalse,
      reason: '超阈值必须走快照而非全量日志',
    );
    container.dispose();
    f.dispose();
  });
}

Layer _layer(String id, String name, int order, bool visible) =>
    Layer(id: id, name: name, order: order, visible: visible);
