import 'dart:async';
import 'package:taraxacum_draw/domain/envelope.dart';
import 'package:taraxacum_draw/domain/ids.dart';

/// 连接方式（p2p-transport 规格的"当前连接方式可见"）。
enum ConnectionMode { lan, webrtc, manual }

extension ConnectionModeX on ConnectionMode {
  String get label => switch (this) {
        ConnectionMode.lan => '局域网直连',
        ConnectionMode.webrtc => '跨网直连',
        ConnectionMode.manual => '手动信令',
      };
}

/// 对端事件类型。
enum PeerEventKind { joined, left, lost }

class PeerEvent {
  const PeerEvent({required this.peer, required this.kind});

  final PeerId peer;
  final PeerEventKind kind;
}

/// 局域网端点（mDNS 解析结果）。
class LanEndpoint {
  const LanEndpoint({required this.host, required this.port});

  final String host;
  final int port;

  @override
  bool operator ==(Object other) =>
      other is LanEndpoint && other.host == host && other.port == port;

  @override
  int get hashCode => Object.hash(host, port);

  @override
  String toString() => '$host:$port';
}

/// 发现的房间（mDNS 等自动发现来源）。
class DiscoveredRoom {
  const DiscoveredRoom({
    required this.roomId,
    required this.hostPeerId,
    required this.name,
    required this.memberCount,
    required this.endpoint,
  });

  final RoomId roomId;
  final PeerId hostPeerId;
  final String name;
  final int memberCount;
  final LanEndpoint endpoint;
}

/// 一条点对点可靠有序链路。
abstract class PeerLink {
  PeerLink();

  /// 对端身份，来自首条消息的信封 from；未收到消息前为 'unknown'。
  PeerId get remotePeer;

  Stream<Envelope> get messages;

  Future<void> send(Envelope message);

  /// 关闭链路。[reason] 决定对端看到的事件语义（left/lost）。
  Future<void> close([PeerEventKind reason = PeerEventKind.left]);

  /// 链路结束时完成，值为结束方式（left/lost）。实现必须保证完成。
  Future<PeerEventKind> get closed;

  bool get isOpen;
}

/// 传输实现基类（design.md D4）。
///
/// 实现负责：链路建立（拨号/接受）、链路级编解码、对端上下线事件。
/// 上层（房间/同步）只面向本接口与 [PeerLink]。
///
/// 订阅契约：[messages]/[peerEvents] 为广播流，**须在 start/dial 之前
/// 订阅**；被动接入请使用带缓冲的 [accept]（事件不丢）。
abstract class Transport {
  Transport({required this.selfPeer});

  final PeerId selfPeer;

  /// 实现向基类发布进站链路的出口（仅实现类使用，勿在业务层引用）。
  // ignore: prefer_final_fields
  StreamController<PeerLink> incomingController =
      StreamController<PeerLink>.broadcast();

  ConnectionMode get mode;

  bool get isRunning => false;

  /// 启动传输：asHost 时同时提供接入（监听/注册），否则仅准备拨号与发现。
  Future<void> start({required bool asHost, required RoomId roomId}) async {}

  Future<void> stop() async {}

  /// 主动拨号；端点类型由实现定义（LAN 为 [LanEndpoint]）。
  Future<PeerLink> dial(Object endpoint);

  /// 取下一条被动接入的链路（带缓冲：start 后、accept 前的进站不丢）。
  Future<PeerLink> accept() {
    if (_pendingLinks.isNotEmpty) {
      return Future.value(_pendingLinks.removeAt(0));
    }
    return (_linkWaiter ??= Completer<PeerLink>()).future;
  }

  /// 由实现调用：发布一条被动接受的链路。
  void publishIncomingLink(PeerLink link) {
    final waiter = _linkWaiter;
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete(link);
      _linkWaiter = null;
    } else {
      _pendingLinks.add(link);
    }
    incomingController.add(link);
  }

  final List<PeerLink> _pendingLinks = [];
  Completer<PeerLink>? _linkWaiter;

  /// 被动接受的进站链路（广播流，晚订阅会丢事件；用 [accept] 代替）。
  Stream<PeerLink> get incomingLinks => incomingController.stream;

  /// 聚合的全部链路消息（按链路解码后）。
  Stream<Envelope> get messages => const Stream.empty();

  /// 对端上下线事件（joined/left/lost）。
  Stream<PeerEvent> get peerEvents => const Stream.empty();

  /// 实现侧自动发现的房间（LAN mDNS；其他实现为空流）。
  Stream<DiscoveredRoom> get discoveredRooms => const Stream.empty();

  // ===== 网状发送（房间层使用；实现类经 [trackLink] 登记链路）=====

  final List<PeerLink> trackedLinks = [];

  /// 实现类在接受/拨号链路后登记；关闭时自动摘除。
  void trackLink(PeerLink link) {
    trackedLinks.add(link);
    link.closed.then((_) => trackedLinks.remove(link));
  }

  /// 广播信封给本传输的全部链路（单条失败不影响其余）。
  Future<void> broadcast(Envelope envelope) async {
    for (final link in List.of(trackedLinks)) {
      if (!link.isOpen) continue;
      try {
        await link.send(envelope);
      } catch (_) {}
    }
  }

  /// 定向发送；返回是否有可达链路。
  Future<bool> sendTo(Envelope envelope, PeerId peer) async {
    var sent = false;
    for (final link in List.of(trackedLinks)) {
      if (!link.isOpen || link.remotePeer != peer) continue;
      try {
        await link.send(envelope);
        sent = true;
      } catch (_) {}
    }
    return sent;
  }
}
