import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart';
/// 数据通道状态。
enum FacadeChannelState { open, closed, failed }

/// 对等连接状态。
enum FacadeConnectionState { connecting, connected, failed, closed }

/// 已建立的数据通道视图。
abstract interface class FacadeDataChannel {
  FacadeChannelState get state;
  Stream<FacadeChannelState> get stateStream;
  Stream<Uint8List> get binaryMessages;
  Future<void> sendBinary(Uint8List bytes);
  Future<void> close();
}

/// 对等连接外观：屏蔽 flutter_webrtc，使 WebRtcTransport 的
/// join/offer/answer 状态机可以脱离平台插件测试（task 3.3）。
abstract interface class PeerConnectionFacade {
  /// 主控侧创建可靠有序数据通道。
  Future<FacadeDataChannel> createDataChannel(String label);

  /// 被控侧收到数据通道。
  Stream<FacadeDataChannel> get onDataChannel;

  Future<void> setRemoteDescription(String sdp, String type);
  Future<String> createOffer();
  Future<String> createAnswer();
  Future<void> setLocalDescription(String sdp, String type);

  /// 本端描述（非 trickle：ICE 收集完成后调用，含候选）。
  Future<String> localDescriptionSdp();

  Stream<FacadeConnectionState> get connectionState;

  Future<void> close();
}

/// flutter_webrtc 真实实现。
class RealPeerConnectionFacade implements PeerConnectionFacade {
  RealPeerConnectionFacade._(this._pc) {
    _pc.onDataChannel = (channel) {
      _onDataChannel.add(RealFacadeDataChannel(channel));
    };
    _pc.onConnectionState = (state) {
      _connectionState.add(_mapConnectionState(state));
    };
    _pc.onIceGatheringState = (state) {
      _gatheringStates.add(state);
    };
  }

  final RTCPeerConnection _pc;
  final StreamController<FacadeDataChannel> _onDataChannel =
      StreamController<FacadeDataChannel>.broadcast();
  final StreamController<FacadeConnectionState> _connectionState =
      StreamController<FacadeConnectionState>.broadcast();
  final StreamController<RTCIceGatheringState> _gatheringStates =
      StreamController<RTCIceGatheringState>.broadcast();

  static const Map<String, dynamic> _config = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
    ],
    'sdpSemantics': 'unified-plan',
  };

  /// 创建真实对等连接（公共 STUN 打洞，design.md D4）。
  static Future<RealPeerConnectionFacade> create() async {
    final pc = await createPeerConnection(_config);
    return RealPeerConnectionFacade._(pc);
  }

  static FacadeConnectionState _mapConnectionState(RTCPeerConnectionState s) {
    switch (s) {
      case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
        return FacadeConnectionState.connected;
      case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
        return FacadeConnectionState.failed;
      case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
        return FacadeConnectionState.closed;
      default:
        return FacadeConnectionState.connecting;
    }
  }

  static FacadeChannelState _mapChannelState(RTCDataChannelState s) {
    switch (s) {
      case RTCDataChannelState.RTCDataChannelOpen:
        return FacadeChannelState.open;
      case RTCDataChannelState.RTCDataChannelClosing:
      case RTCDataChannelState.RTCDataChannelClosed:
        return FacadeChannelState.closed;
      default:
        return FacadeChannelState.failed;
    }
  }

  @override
  Future<FacadeDataChannel> createDataChannel(String label) async {
    // 不设 maxRetransmits/maxPacketLifeTime ⇒ reliable 有序（规格要求）。
    final init = RTCDataChannelInit()..ordered = true;
    final channel = await _pc.createDataChannel(label, init);
    return RealFacadeDataChannel(channel);
  }

  @override
  Stream<FacadeDataChannel> get onDataChannel => _onDataChannel.stream;

  @override
  Future<void> setRemoteDescription(String sdp, String type) =>
      _pc.setRemoteDescription(RTCSessionDescription(sdp, type));

  @override
  Future<String> createOffer() async =>
      (await _pc.createOffer()).sdp ??

      (throw StateError('createOffer 返回空描述'));

  @override
  Future<String> createAnswer() async =>
      (await _pc.createAnswer()).sdp ??

      (throw StateError('createAnswer 返回空描述'));

  @override
  Future<void> setLocalDescription(String sdp, String type) async {
    await _pc.setLocalDescription(RTCSessionDescription(sdp, type));
    // 非 trickle：等待 ICE 收集完成（事件不可靠时 1.5s 兜底）。
    if (_pc.iceGatheringState !=
        RTCIceGatheringState.RTCIceGatheringStateComplete) {
      try {
        await _gatheringStates.stream
            .firstWhere(
              (s) => s == RTCIceGatheringState.RTCIceGatheringStateComplete,
            )
            .timeout(const Duration(milliseconds: 1500));
      } on TimeoutException {
        // 兜底：直接使用当前已收集的候选。
      }
    }
  }

  @override
  Future<String> localDescriptionSdp() async =>
      (await _pc.getLocalDescription())?.sdp ??

      (throw StateError('localDescription 为空'));

  @override
  Stream<FacadeConnectionState> get connectionState => _connectionState.stream;

  @override
  Future<void> close() => _pc.close();
}

/// [RealPeerConnectionFacade] 的数据通道视图。
class RealFacadeDataChannel implements FacadeDataChannel {
  RealFacadeDataChannel(this._channel);

  final RTCDataChannel _channel;

  @override
  FacadeChannelState get state {
    final state = _channel.state;
    if (state == null) return FacadeChannelState.failed;
    return RealPeerConnectionFacade._mapChannelState(state);
  }

  @override
  Stream<FacadeChannelState> get stateStream =>
      _channel.stateChangeStream.map(RealPeerConnectionFacade._mapChannelState);

  @override
  Stream<Uint8List> get binaryMessages =>
      _channel.messageStream.map((m) => m.binary);

  @override
  Future<void> sendBinary(Uint8List bytes) =>
      _channel.send(RTCDataChannelMessage.fromBinary(bytes));

  @override
  Future<void> close() => _channel.close();
}
