import 'dart:async';
import 'dart:typed_data';

/// 信令通道上的一条消息（join/offer/answer 等，JSON 承载）。
class SignalingMessage {
  const SignalingMessage({
    required this.topic,
    required this.type,
    required this.from,
    required this.data,
    this.to,
  });

  final String topic;
  final String type; // join / offer / answer / bye
  final String from;
  final String? to;
  final Uint8List data; // 加密后的载荷（SDP 等）

  Map<String, Object> toJson() => {
        't': type,
        'f': from,
        'to': ?to,
        'd': String.fromCharCodes(data),
      };

  static SignalingMessage fromJson(String topic, Map<Object?, Object?> json) {
    final data = (json['d'] as String?) ?? '';
    return SignalingMessage(
      topic: topic,
      type: (json['t'] as String?) ?? '',
      from: (json['f'] as String?) ?? '',
      to: json['to'] as String?,
      data: Uint8List.fromList(data.codeUnits),
    );
  }
}

/// 信令客户端（rendezvous 中继）。
///
/// 生产实现为公共 MQTT over WebSocket 中继（多服务器依次尝试）；
/// 测试用内存总线实现同一接口。
abstract class SignalingClient {
  /// 连接中继（实现可内部尝试多个服务器）。
  Future<void> connect();

  /// 订阅主题（加入前调用）。
  Future<void> subscribe(String topic);

  /// 发布消息到主题。
  Future<void> publish(SignalingMessage message);

  /// 收到的信令消息。
  Stream<SignalingMessage> get messages;

  /// 是否已连接。
  bool get isConnected;

  /// 断开并释放。
  Future<void> close();
}

/// 内存总线：同一 [topic] 内的客户端互收消息（测试用）。
class InMemorySignalingBus {
  final Map<String, List<InMemorySignalingClient>> _topics = {};

  InMemorySignalingClient attach(String selfPeer) =>
      InMemorySignalingClient._(this, selfPeer);

  void _subscribe(String topic, InMemorySignalingClient client) {
    _topics.putIfAbsent(topic, () => []).add(client);
  }

  Future<void> _publish(SignalingMessage message) async {
    final receivers = List.of(_topics[message.topic] ?? const []);
    for (final receiver in receivers) {
      if (receiver.selfPeer == message.from) continue;
      // 模拟网络异步投递（真实信令必有传输时延）。
      scheduleMicrotask(() => receiver.acceptMessage(message));
    }
  }

  void _unsubscribe(String topic, InMemorySignalingClient client) {
    _topics[topic]?.remove(client);
  }
}

class InMemorySignalingClient implements SignalingClient {
  InMemorySignalingClient._(this._bus, this.selfPeer);

  final InMemorySignalingBus _bus;
  final String selfPeer;
  final StreamController<SignalingMessage> _messages =
      StreamController<SignalingMessage>.broadcast();
  final Set<String> _topics = {};
  bool _connected = false;

  @override
  bool get isConnected => _connected;

  @override
  Stream<SignalingMessage> get messages => _messages.stream;  @override
  Future<void> connect() async {
    _connected = true;
  }

  @override
  Future<void> subscribe(String topic) async {
    _topics.add(topic);
    _bus._subscribe(topic, this);
  }

  @override
  Future<void> publish(SignalingMessage message) async {
    if (!_connected) throw StateError('信令未连接');
    await _bus._publish(message);
  }

  @override
  Future<void> close() async {
    for (final topic in _topics) {
      _bus._unsubscribe(topic, this);
    }
    _topics.clear();
    _connected = false;
    await _messages.close();
  }

  /// 总线投递入口（仅 [InMemorySignalingBus] 调用）。
  void acceptMessage(SignalingMessage message) {
    if (!_messages.isClosed) _messages.add(message);
  }
}
