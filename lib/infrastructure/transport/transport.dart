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

  Future<void> close();

  bool get isOpen;
}

/// 传输实现基类（design.md D4）。
///
/// 实现负责：链路建立（拨号/接受）、链路级编解码、对端上下线事件。
/// 上层（房间/同步）只面向本接口与 [PeerLink]。
abstract class Transport {
  Transport({required this.selfPeer});

  final PeerId selfPeer;

  ConnectionMode get mode;

  bool get isRunning => false;

  /// 启动传输：asHost 时同时提供接入（监听/注册），否则仅准备拨号与发现。
  Future<void> start({required bool asHost, required RoomId roomId}) async {}

  Future<void> stop() async {}

  /// 主动拨号；端点类型由实现定义（LAN 为 [LanEndpoint]）。
  Future<PeerLink> dial(Object endpoint);

  /// 被动接受的进站链路（房主侧）。
  Stream<PeerLink> get incomingLinks => const Stream.empty();

  /// 聚合的全部链路消息（按链路解码后）。
  Stream<Envelope> get messages => const Stream.empty();

  /// 对端上下线事件（joined/left/lost）。
  Stream<PeerEvent> get peerEvents => const Stream.empty();

  /// 实现侧自动发现的房间（LAN mDNS；其他实现为空流）。
  Stream<DiscoveredRoom> get discoveredRooms => const Stream.empty();
}
