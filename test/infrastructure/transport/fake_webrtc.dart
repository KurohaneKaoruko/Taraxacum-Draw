import 'dart:async';
import 'dart:typed_data';

import 'package:taraxacum_draw/infrastructure/transport/webrtc/peer_connection_facade.dart';

/// 成对出现的假对等连接网络：按创建顺序配对。先创建者为成员侧
/// （等 offer），后创建者为房主侧（createDataChannel + offer）——
/// 与 WebRtcTransport 的真实时序一致。
class FakeWebRtcNetwork {
  FakePeerConnection? _waiting;

  Future<PeerConnectionFacade> create() async {
    final pc = FakePeerConnection._();
    final waiting = _waiting;
    if (waiting != null) {
      waiting._pairWith(pc);
      _waiting = null;
    } else {
      _waiting = pc;
    }
    return pc;
  }
}

class FakePeerConnection implements PeerConnectionFacade {
  FakePeerConnection._();

  FakePeerConnection? _counterpart;
  FakeDataChannel? _createdPair;
  final StreamController<FacadeDataChannel> _incomingChannels =
      StreamController<FacadeDataChannel>.broadcast();
  final StreamController<FacadeConnectionState> _states =
      StreamController<FacadeConnectionState>.broadcast();
  String? _localSdp;

  @override
  Stream<FacadeDataChannel> get onDataChannel => _incomingChannels.stream;

  @override
  Stream<FacadeConnectionState> get connectionState => _states.stream;

  void _pairWith(FakePeerConnection other) {
    _counterpart = other;
    other._counterpart = this;
  }

  @override
  Future<FacadeDataChannel> createDataChannel(String label) async {
    assert(_counterpart != null, '配对前不能创建数据通道');
    final pair = FakeDataChannel._pair();
    _createdPair = pair;
    _counterpart!._incomingChannels.add(pair.remoteView);
    return pair.localView;
  }
  @override
  Future<void> setRemoteDescription(String sdp, String type) async {
    // answer 应用完成即视为双方连接建立（ICE 全通）。
    if (type == 'answer') {
      _counterpart?._createdPair?._markOpen();
      _createdPair?._markOpen();
      _states.add(FacadeConnectionState.connected);
      _counterpart?._states.add(FacadeConnectionState.connected);
    }
  }

  @override
  Future<String> createOffer() async => 'fake-offer';

  @override
  Future<String> createAnswer() async => 'fake-answer';

  @override
  Future<void> setLocalDescription(String sdp, String type) async {
    _localSdp = sdp;
  }

  @override
  Future<String> localDescriptionSdp() async => _localSdp ?? 'fake-local';

  @override
  Future<void> close() async {
    _createdPair?._markClosed();
    _counterpart?._createdPair?._markClosed();
    _states.add(FacadeConnectionState.closed);
    _counterpart?._states.add(FacadeConnectionState.closed);
  }
}

/// 一条通道的两端视图。
class FakeDataChannel {
  FakeDataChannel._pair() {
    _localView = _View(this);
    _remoteView = _View(this);
  }

  late final _View _localView;
  late final _View _remoteView;

  /// 对外暴露的通道视图。
  FacadeDataChannel get localView => _localView;
  FacadeDataChannel get remoteView => _remoteView;

  bool _open = false;
  bool _closed = false;

  void _markOpen() {
    if (_open || _closed) return;
    _open = true;
    _localView._states.add(FacadeChannelState.open);
    _remoteView._states.add(FacadeChannelState.open);
  }

  void _markClosed() {
    if (_closed) return;
    _closed = true;
    for (final view in [_localView, _remoteView]) {
      view._states.add(FacadeChannelState.closed);
      view._incoming.close();
    }
  }

  void _send(_View from, Uint8List bytes) {
    final to = identical(from, _localView) ? _remoteView : _localView;
    if (_closed) throw StateError('通道已关闭');
    to._incoming.add(bytes);
  }
}

class _View implements FacadeDataChannel {
  _View(this._owner);

  final FakeDataChannel _owner;
  final StreamController<Uint8List> _incoming =
      StreamController<Uint8List>.broadcast();
  final StreamController<FacadeChannelState> _states =
      StreamController<FacadeChannelState>.broadcast();

  @override
  FacadeChannelState get state => _owner._open
      ? FacadeChannelState.open
      : (_owner._closed ? FacadeChannelState.closed : FacadeChannelState.failed);

  @override
  Stream<FacadeChannelState> get stateStream => _states.stream;

  @override
  Stream<Uint8List> get binaryMessages => _incoming.stream;

  @override
  Future<void> sendBinary(Uint8List bytes) => Future<void>.sync(() {
        if (!_owner._open) throw StateError('通道未打开');
        _owner._send(this, bytes);
      });

  @override
  Future<void> close() async => _owner._markClosed();
}
