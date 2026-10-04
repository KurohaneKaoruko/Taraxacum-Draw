import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:bonsoir/bonsoir.dart';
import 'package:taraxacum_draw/domain/envelope.dart';
import 'package:taraxacum_draw/domain/ids.dart';
import 'package:taraxacum_draw/infrastructure/transport/envelope_codec.dart';
import 'package:taraxacum_draw/infrastructure/transport/heartbeat.dart';
import 'package:taraxacum_draw/infrastructure/transport/transport.dart';

/// mDNS 服务类型（iOS NSBonjourServices 已同步声明）。
const String kLanServiceType = '_taraxacum._tcp';

/// 局域网链路：TCP 上的长度前缀帧。
class LanPeerLink extends PeerLink {
  LanPeerLink._(this._socket) {
    _socket.listen(
      _onData,
      onDone: () => _finish(PeerEventKind.left),
      onError: (Object _) => _finish(PeerEventKind.lost),
      cancelOnError: true,
    );
  }

  final Socket _socket;
  final FrameSplitter _splitter = FrameSplitter();
  final StreamController<Envelope> _messages =
      StreamController<Envelope>.broadcast();
  final Completer<PeerEventKind> _closed = Completer<PeerEventKind>();
  PeerId? _remotePeerId;
  bool _open = true;

  /// 链路结束时完成，值为结束方式（left=正常关闭 / lost=异常断开）。
  Future<PeerEventKind> get closed => _closed.future;

  @override
  PeerId get remotePeer => _remotePeerId ?? 'unknown';

  @override
  bool get isOpen => _open;

  @override
  Stream<Envelope> get messages => _messages.stream;

  @override
  Future<void> send(Envelope message) async {
    if (!_open) throw StateError('链路已关闭');
    _socket.add(frameEnvelope(EnvelopeCodec.encode(message)));
  }

  @override
  Future<void> close([PeerEventKind reason = PeerEventKind.left]) async {
    _finish(reason);
    // 对端已销毁连接时 flush 可能永不完成，超时兜底。
    await _socket.flush().timeout(
          const Duration(seconds: 1),
          onTimeout: () {},
        );
    _socket.destroy();
  }

  void _onData(List<int> chunk) {
    final List<Uint8List> frames;
    try {
      frames = _splitter.push(chunk);
    } on FormatException {
      _finish(PeerEventKind.lost);
      _socket.destroy();
      return;
    }
    for (final frame in frames) {
      try {
        final envelope = EnvelopeCodec.decode(frame);
        _remotePeerId ??= envelope.from;
        _messages.add(envelope);
      } on FormatException {
        _finish(PeerEventKind.lost);
        _socket.destroy();
        return;
      }
    }
  }

  void _finish(PeerEventKind kind) {
    if (!_open) return;
    _open = false;
    _messages.close();
    if (!_closed.isCompleted) _closed.complete(kind);
  }

  static Future<LanPeerLink> dial(LanEndpoint endpoint) async {
    final socket = await Socket.connect(
      endpoint.host,
      endpoint.port,
      timeout: const Duration(seconds: 5),
    );
    return LanPeerLink._(socket);
  }
}

/// 局域网传输：mDNS 注册/发现 + TCP 直连（task 3.2）。
///
/// 房主：绑定随机端口 + mDNS 广播房间信息（TXT: room/peer/count）。
/// 成员：mDNS 浏览发现房间（[discoveredRooms]），拨号 [dial] 加入。
///
/// [enableMdns] 供测试环境关闭（无插件平台）。
class LanTransport extends Transport {
  LanTransport({
    required super.selfPeer,
    this.enableMdns = true,
    this.serviceNamePrefix = 'TD',
    this.heartbeatInterval = const Duration(seconds: 3),
    this.heartbeatTimeout = const Duration(seconds: 10),
  });

  static const String _roomAttr = 'room';
  static const String _peerAttr = 'peer';
  static const String _countAttr = 'count';

  final bool enableMdns;
  final String serviceNamePrefix;
  final Duration heartbeatInterval;
  final Duration heartbeatTimeout;

  ServerSocket? _server;
  BonsoirBroadcast? _broadcast;
  BonsoirDiscovery? _discovery;
  StreamSubscription<BonsoirDiscoveryEvent>? _discoverySub;

  final StreamController<Envelope> _messages =
      StreamController<Envelope>.broadcast();
  final StreamController<PeerEvent> _peerEvents =
      StreamController<PeerEvent>.broadcast();
  final StreamController<DiscoveredRoom> _rooms =
      StreamController<DiscoveredRoom>.broadcast();
  final Map<PeerId, LanPeerLink> _links = {};
  final Map<PeerId, LinkHeartbeat> _heartbeats = {};
  final Set<String> _announcedRoomIds = {};

  bool _running = false;
  RoomId? _roomId;

  @override
  ConnectionMode get mode => ConnectionMode.lan;

  @override
  bool get isRunning => _running;

  @override
  Stream<Envelope> get messages => _messages.stream;

  @override
  Stream<PeerEvent> get peerEvents => _peerEvents.stream;

  @override
  Stream<DiscoveredRoom> get discoveredRooms => _rooms.stream;

  /// 房主绑定后的端口（0 = 未作为房主启动）。
  int get boundPort => _server?.port ?? 0;

  @override
  Future<void> start({
    required bool asHost,
    required RoomId roomId,
    String? roomKey,
  }) async {
    if (_running) return;
    _roomId = roomId;
    if (asHost) {
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
      _server!.listen(
        (socket) {
          final link = LanPeerLink._(socket);
          _attach(link);
          publishIncomingLink(link);
        },
        onError: (Object _) {},
      );
      if (enableMdns) await _register(roomId);
    } else if (enableMdns) {
      await _startDiscovery();
    }
    _running = true;
  }

  @override
  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    await _discoverySub?.cancel();
    await _broadcast?.stop();
    await _discovery?.stop();
    await _server?.close();
    _server = null;
    for (final link in List.of(_links.values)) {
      await link.close();
    }
    _links.clear();
    for (final heartbeat in _heartbeats.values) {
      heartbeat.dispose();
    }
    _heartbeats.clear();
    await incomingController.close();
    await _messages.close();
    await _peerEvents.close();
    await _rooms.close();
  }

  @override
  Future<PeerLink> dial(Object endpoint) async {
    final link = await LanPeerLink.dial(endpoint as LanEndpoint);
    _attach(link);
    return link;
  }

  void _attach(LanPeerLink link) {
    link.messages.listen((envelope) {
      final peer = link.remotePeer;
      if (peer != 'unknown' && !_links.containsKey(peer)) {
        _links[peer] = link;
        _heartbeats[peer] = LinkHeartbeat(
          link: link,
          selfPeer: selfPeer,
          roomId: envelope.roomId,
          interval: heartbeatInterval,
          timeout: heartbeatTimeout,
        );
        _peerEvents.add(PeerEvent(peer: peer, kind: PeerEventKind.joined));
      }
      _messages.add(envelope);
    });
    // 终止事件只来自 link.closed（区分 left/lost），避免双路竞争。
    link.closed.then((kind) => _detach(link, closedKind: kind));
  }

  void _detach(LanPeerLink link, {PeerEventKind? closedKind}) {
    final peer = link.remotePeer;
    if (peer == 'unknown' || !_links.containsKey(peer)) return;
    _links.remove(peer);
    _heartbeats.remove(peer)?.dispose();
    _peerEvents.add(PeerEvent(peer: peer, kind: closedKind ?? PeerEventKind.left));
  }

  Future<void> _register(RoomId roomId) async {
    final service = BonsoirService(
      name: '$serviceNamePrefix-${selfPeer.substring(0, 8)}',
      type: kLanServiceType,
      port: _server!.port,
      attributes: {_roomAttr: roomId, _peerAttr: selfPeer},
    );
    _broadcast = BonsoirBroadcast(service: service);
    await _broadcast!.initialize();
    await _broadcast!.start();
  }

  Future<void> _startDiscovery() async {
    _discovery = BonsoirDiscovery(type: kLanServiceType);
    await _discovery!.initialize();
    await _discovery!.start();
    _discoverySub = _discovery!.eventStream?.listen((event) async {
      switch (event) {
        case BonsoirDiscoveryServiceFoundEvent(:final service):
          // 找到即解析，解析结果以 Resolved 事件到达。
          await _discovery!.serviceResolver.resolveService(service);
        case BonsoirDiscoveryServiceResolvedEvent(:final service):
          _publishRoom(service);
        case BonsoirDiscoveryServiceLostEvent(:final service):
          _announcedRoomIds.remove(service.attributes[_roomAttr]);
        default:
          break;
      }
    });
  }

  void _publishRoom(BonsoirService service) {
    final roomId = service.attributes[_roomAttr];
    if (roomId == null || roomId == _roomId) return;
    if (service.hostAddresses.isEmpty) return;
    if (!_announcedRoomIds.add(roomId)) return; // 每房间只发布一次
    _rooms.add(DiscoveredRoom(
      roomId: roomId,
      hostPeerId: service.attributes[_peerAttr] ?? 'unknown',
      name: service.name,
      memberCount: int.tryParse(service.attributes[_countAttr] ?? '') ?? 1,
      endpoint: LanEndpoint(
        host: service.hostAddresses.first,
        port: service.port,
      ),
    ));
  }
}
