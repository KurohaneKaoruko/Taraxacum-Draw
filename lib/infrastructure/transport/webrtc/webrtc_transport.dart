import 'dart:async';
import 'dart:typed_data';

import 'package:taraxacum_draw/domain/envelope.dart';
import 'package:taraxacum_draw/domain/ids.dart';
import 'package:taraxacum_draw/infrastructure/transport/envelope_codec.dart';
import 'package:taraxacum_draw/infrastructure/transport/heartbeat.dart';
import 'package:taraxacum_draw/infrastructure/transport/signaling/signaling.dart';
import 'package:taraxacum_draw/infrastructure/transport/signaling/signaling_crypto.dart';
import 'package:taraxacum_draw/infrastructure/transport/transport.dart';
import 'package:taraxacum_draw/infrastructure/transport/webrtc/peer_connection_facade.dart';

/// WebRTC 端点：房间号 + 房间密钥（信令派生与载荷解密都需要）。
class WebRtcEndpoint {
  const WebRtcEndpoint({required this.roomId, required this.roomKey});

  final RoomId roomId;
  final String roomKey;
}

/// WebRTC 链路：可靠有序 DataChannel 上的信封帧。
class WebRtcPeerLink extends PeerLink {
  WebRtcPeerLink._(
    this._facade,
    this._channel, {
    required PeerId remotePeer,
  })  : _remotePeer = remotePeer {
    _stateSub = _channel.stateStream.listen((state) {
      if (_open && state != FacadeChannelState.open) {
        _finish(PeerEventKind.left);
      }
    });
    _connectionSub = _facade.connectionState.listen((state) {
      if (_open && state == FacadeConnectionState.failed) {
        _finish(PeerEventKind.lost);
      }
    });
    _messageSub = _channel.binaryMessages.listen(_onBinary, onDone: () {
      _finish(PeerEventKind.left);
    });
  }

  final PeerConnectionFacade _facade;
  final FacadeDataChannel _channel;
  final FrameSplitter _splitter = FrameSplitter();
  final StreamController<Envelope> _messages =
      StreamController<Envelope>.broadcast();
  final Completer<PeerEventKind> _closed = Completer<PeerEventKind>();

  StreamSubscription<FacadeChannelState>? _stateSub;
  StreamSubscription<FacadeConnectionState>? _connectionSub;
  StreamSubscription<Uint8List>? _messageSub;

  final PeerId _remotePeer;
  bool _open = true;

  @override
  PeerId get remotePeer => _remotePeer;

  @override
  bool get isOpen => _open;

  @override
  Stream<Envelope> get messages => _messages.stream;

  @override
  Future<PeerEventKind> get closed => _closed.future;

  @override
  Future<void> send(Envelope message) async {
    if (!_open) throw StateError('链路已关闭');
    await _channel.sendBinary(frameEnvelope(EnvelopeCodec.encode(message)));
  }

  @override
  Future<void> close([PeerEventKind reason = PeerEventKind.left]) async {
    _finish(reason);
    await _facade.close();
  }

  void _onBinary(Uint8List chunk) {
    final List<Uint8List> frames;
    try {
      frames = _splitter.push(chunk);
    } on FormatException {
      _finish(PeerEventKind.lost);
      return;
    }
    for (final frame in frames) {
      try {
        _messages.add(EnvelopeCodec.decode(frame));
      } on FormatException {
        _finish(PeerEventKind.lost);
        return;
      }
    }
  }

  void _finish(PeerEventKind kind) {
    if (!_open) return;
    _open = false;
    _stateSub?.cancel();
    _connectionSub?.cancel();
    _messageSub?.cancel();
    _messages.close();
    if (!_closed.isCompleted) _closed.complete(kind);
  }
}

/// WebRTC 传输：公共信令 rendezvous + 加密 SDP 交换 + 可靠 DataChannel。
///
/// 流程（非 trickle，design.md D4）：
/// 1. 双方连接信令并订阅 `signalingTopic(roomId, roomKey)`；
/// 2. 成员发布 join → 房主创建数据通道 + offer（加密后定向回复）；
/// 3. 成员 setRemote → answer → 房主 setRemote → 连接建立；
/// 4. DataChannel 打开后即 [PeerLink]，信封帧与 LAN 完全一致。
class WebRtcTransport extends Transport {
  WebRtcTransport({
    required super.selfPeer,
    required SignalingClient signaling,
    required Future<PeerConnectionFacade> Function() connectionFactory,
    this.heartbeatInterval = const Duration(seconds: 3),
    this.heartbeatTimeout = const Duration(seconds: 10),
  })  : _signaling = signaling,
        _connectionFactory = connectionFactory;

  final SignalingClient _signaling;
  final Future<PeerConnectionFacade> Function() _connectionFactory;
  final Duration heartbeatInterval;
  final Duration heartbeatTimeout;

  final StreamController<Envelope> _messages =
      StreamController<Envelope>.broadcast();
  final StreamController<PeerEvent> _peerEvents =
      StreamController<PeerEvent>.broadcast();
  final Map<PeerId, WebRtcPeerLink> _links = {};
  final Map<PeerId, LinkHeartbeat> _heartbeats = {};

  /// 被控端在 offer 到达前创建的连接（按远端身份索引）。
  final Map<PeerId, Future<WebRtcPeerLink>> _dialing = {};

  bool _running = false;
  bool _asHost = false;
  SignalingCrypto? _crypto;
  String? _topic;

  @override
  ConnectionMode get mode => ConnectionMode.webrtc;

  @override
  bool get isRunning => _running;

  @override
  Stream<Envelope> get messages => _messages.stream;

  @override
  Stream<PeerEvent> get peerEvents => _peerEvents.stream;

  @override
  Future<void> start({
    required bool asHost,
    required RoomId roomId,
    String? roomKey,
  }) async {
    if (_running) return;
    _asHost = asHost;
    _topic = await signalingTopic(roomId, roomKey ?? '');
    _crypto = await SignalingCrypto.create(roomId: roomId, roomKey: roomKey ?? '');
    await _signaling.connect();
    await _signaling.subscribe(_topic!);
    _signaling.messages.listen(_onSignaling);
    _running = true;
  }

  @override
  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    for (final heartbeat in _heartbeats.values) {
      heartbeat.dispose();
    }
    _heartbeats.clear();
    for (final link in List.of(_links.values)) {
      await link.close();
    }
    _links.clear();
    await _signaling.close();
    await incomingController.close();
    await _messages.close();
    await _peerEvents.close();
  }

  @override
  Future<PeerLink> dial(Object endpoint) async {
    final ep = endpoint as WebRtcEndpoint;
    if (!_running) {
      await start(asHost: false, roomId: ep.roomId, roomKey: ep.roomKey);
    }
    // 加入流程：publish join → 收 offer → answer → 链路就绪。
    final dialFuture = (_dialing[ep.roomId] ??= _join(ep));
    try {
      return await dialFuture.timeout(const Duration(seconds: 15));
    } finally {
      _dialing.remove(ep.roomId);
    }
  }

  Future<WebRtcPeerLink> _join(WebRtcEndpoint endpoint) async {
    // 先准备好本端连接与通道监听，再发布 join（时序安全）。
    final facade = await _connectionFactory();
    final channelCompleter = Completer<FacadeDataChannel>();
    final sub = facade.onDataChannel.listen(channelCompleter.complete);

    final offerFuture = _signaling.messages
        .firstWhere(
          (m) => m.type == 'offer' && (m.to == null || m.to == selfPeer),
        )
        .timeout(const Duration(seconds: 15));
    await _signaling.publish(SignalingMessage(
      topic: _topic!,
      type: 'join',
      from: selfPeer,
      data: Uint8List(0),
    ));

    final offer = await offerFuture;
    final plainSdp = await _crypto!.decrypt(offer.data);
    await facade.setRemoteDescription(plainSdp, 'offer');
    final answerSdp = await facade.createAnswer();
    await facade.setLocalDescription(answerSdp, 'answer');
    await _signaling.publish(SignalingMessage(
      topic: _topic!,
      type: 'answer',
      from: selfPeer,
      to: offer.from,
      data: await _crypto!.encrypt(answerSdp),
    ));

    final channel = await channelCompleter.future.timeout(
      const Duration(seconds: 15),
    );
    sub.cancel();
    final link = WebRtcPeerLink._(facade, channel, remotePeer: offer.from);
    _registerLink(link);
    return link;
  }

  Future<void> _onSignaling(SignalingMessage message) async {
    if (message.topic != _topic || message.from == selfPeer) return;
    final crypto = _crypto;
    if (crypto == null) return;

    switch (message.type) {
      case 'join':
        if (!_asHost) return;
        if (message.to != null && message.to != selfPeer) return;
        await _acceptJoin(message, crypto);
      case 'answer':
        // 由 _join 的 firstWhere 处理。
        break;
      case 'bye':
        final peer = message.from;
        final link = _links[peer];
        await link?.close(PeerEventKind.left);
      default:
        break;
    }
  }

  Future<void> _acceptJoin(
    SignalingMessage join,
    SignalingCrypto crypto,
  ) async {
    final facade = await _connectionFactory();
    final channel = await facade.createDataChannel('taraxacum');

    // 非 trickle：真实实现会在 setLocal 内等待 ICE 收集完成。
    final offerSdp = await facade.createOffer();
    await facade.setLocalDescription(offerSdp, 'offer');
    final fullOfferSdp = await facade.localDescriptionSdp();

    // 先订阅 answer，再发布 offer（时序安全）。
    final answerFuture = _signaling.messages
        .firstWhere(
          (m) => m.type == 'answer' && m.from == join.from,
        )
        .timeout(const Duration(seconds: 15));
    await _signaling.publish(SignalingMessage(
      topic: _topic!,
      type: 'offer',
      from: selfPeer,
      to: join.from,
      data: await crypto.encrypt(fullOfferSdp),
    ));

    final answer = await answerFuture;
    await facade.setRemoteDescription(await crypto.decrypt(answer.data),
        'answer');

    final link = WebRtcPeerLink._(facade, channel, remotePeer: join.from);
    _registerLink(link);
    publishIncomingLink(link);
  }

  void _registerLink(WebRtcPeerLink link) {
    trackLink(link);
    final peer = link.remotePeer;
    _links[peer] = link;
    _peerEvents.add(PeerEvent(peer: peer, kind: PeerEventKind.joined));
    _heartbeats[peer] = LinkHeartbeat(
      link: link,
      selfPeer: selfPeer,
      roomId: _roomIdOfTopic(),
      interval: heartbeatInterval,
      timeout: heartbeatTimeout,
    );
    link.messages.listen(
      (envelope) => _messages.add(envelope),
      onDone: () => _detach(link),
    );
    link.closed.then((kind) => _detach(link, closedKind: kind));
  }

  void _detach(WebRtcPeerLink link, {PeerEventKind? closedKind}) {
    final peer = link.remotePeer;
    if (!_links.containsKey(peer)) return;
    _links.remove(peer);
    _heartbeats.remove(peer)?.dispose();
    _peerEvents
        .add(PeerEvent(peer: peer, kind: closedKind ?? PeerEventKind.left));
  }

  // 信令主题派生已含 roomId；心跳信封的 roomId 用占位即可（仅传输内语义）。
  RoomId _roomIdOfTopic() => 'webrtc-${_topic?.hashCode ?? 0}';
}
