import 'dart:async';
import 'dart:convert';

import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:taraxacum_draw/infrastructure/transport/signaling/signaling.dart';

/// 公共 MQTT 中继配置（免费公共服务，design.md D4）。
class MqttBroker {
  const MqttBroker(this.host, this.port);

  final String host;
  final int port;
}

/// 生产信令客户端：公共 MQTT over WebSocket 中继，多服务器依次尝试。
///
/// 仅用于交换加密后的握手信息（SDP/ICE），绘画数据走 DataChannel 直连；
/// 主题名经 `signalingTopic` 哈希派生，中继上不出现明文 roomId。
///
/// 真实跨网连通性（打洞成功率、公共中继可用性）在 task 7.1 双设备验收。
class MqttSignalingClient implements SignalingClient {
  MqttSignalingClient({
    this.brokers = defaultBrokers,
    String? clientId,
  }) : _clientId = clientId ?? 'td-${DateTime.now().millisecondsSinceEpoch}';

  static const List<MqttBroker> defaultBrokers = [
    MqttBroker('broker.emqx.io', 8083),
    MqttBroker('broker.hivemq.com', 8000),
    MqttBroker('test.mosquitto.org', 8080),
  ];

  final List<MqttBroker> brokers;
  final String _clientId;

  MqttServerClient? _client;
  final StreamController<SignalingMessage> _messages =
      StreamController<SignalingMessage>.broadcast();
  StreamSubscription? _updatesSub;
  bool _connected = false;

  @override
  bool get isConnected => _connected;

  @override
  Stream<SignalingMessage> get messages => _messages.stream;

  @override
  Future<void> connect() async {
    Object? lastError;
    for (final broker in brokers) {
      try {
        final client = MqttServerClient.withPort(
          broker.host,
          _clientId,
          broker.port,
        )
          ..useWebSocket = true
          ..websocketProtocols = MqttClientConstants.protocolsSingleDefault
          ..keepAlivePeriod = 20
          ..logging(on: false)
          ..connectionMessage = MqttConnectMessage()
              .withClientIdentifier(_clientId)
              .startClean();
        _client = client;
        await client.connect();
        _updatesSub = client.updates?.listen(_onUpdates);
        _connected = true;
        return;
      } catch (error) {
        lastError = error;
        _client?.disconnect();
        _client = null;
      }
    }
    throw StateError('所有公共信令服务器均不可达: $lastError');
  }

  void _onUpdates(List<MqttReceivedMessage<MqttMessage>> updates) {
    for (final record in updates) {
      final publish = record.payload;
      if (publish is! MqttPublishMessage) continue;
      final text = MqttPublishPayload.bytesToStringAsString(
        publish.payload.message,
      );
      try {
        final json = jsonDecode(text) as Map<Object?, Object?>;
        _messages.add(SignalingMessage.fromJson(record.topic, json));
      } on FormatException {
        // 非本协议的消息，忽略（公共主题可能有噪声）。
      }
    }
  }

  @override
  Future<void> subscribe(String topic) async {
    final client = _client;
    if (client == null || !_connected) throw StateError('信令未连接');
    client.subscribe(topic, MqttQos.atMostOnce);
  }

  @override
  Future<void> publish(SignalingMessage message) async {
    final client = _client;
    if (client == null || !_connected) throw StateError('信令未连接');
    final builder = MqttClientPayloadBuilder()
      ..addString(jsonEncode(message.toJson()));
    client.publishMessage(
      message.topic,
      MqttQos.atMostOnce,
      builder.payload!,
    );
  }

  @override
  Future<void> close() async {
    if (!_connected) return;
    _connected = false;
    await _updatesSub?.cancel();
    _client?.disconnect();
    _client = null;
    await _messages.close();
  }
}
