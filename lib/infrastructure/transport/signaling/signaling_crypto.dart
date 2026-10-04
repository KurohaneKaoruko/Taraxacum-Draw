import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// 信令载荷加密（design.md D4）：SDP/ICE 属于隐私信息，
/// 公共中继只应看到密文。
///
/// 密钥 = SHA-256("taraxacum-signal" | roomId | roomKey)，
/// 算法 = AES-GCM-256，格式 = nonce(12) + cipherText + mac(16)。
class SignalingCrypto {
  SignalingCrypto._(this._keyBytes);

  static const int _nonceLength = 12;
  static const int _macLength = 16;

  final List<int> _keyBytes;
  static final AesGcm _algorithm = AesGcm.with256bits();

  static Future<SignalingCrypto> create({
    required String roomId,
    required String roomKey,
  }) async =>
      SignalingCrypto._(await _derive(roomId, roomKey));

  static Future<List<int>> _derive(String roomId, String roomKey) async {
    final material = utf8.encode('taraxacum-signal|$roomId|$roomKey');
    final hash = await Sha256().hash(material);
    return hash.bytes;
  }

  Future<Uint8List> encrypt(String plainText) async {
    final secretKey = await _algorithm.newSecretKeyFromBytes(_keyBytes);
    final secretBox = await _algorithm.encrypt(
      utf8.encode(plainText),
      secretKey: secretKey,
    );
    return Uint8List.fromList(secretBox.concatenation());
  }

  Future<String> decrypt(Uint8List sealed) async {
    final secretKey = await _algorithm.newSecretKeyFromBytes(_keyBytes);
    final clear = await _algorithm.decrypt(
      SecretBox.fromConcatenation(
        sealed,
        nonceLength: _nonceLength,
        macLength: _macLength,
      ),
      secretKey: secretKey,
    );
    return utf8.decode(clear);
  }
}

/// 信令主题名：经 sha256 派生，避免在公共中继上暴露明文 roomId。
Future<String> signalingTopic(String roomId, String roomKey) async {
  final digest =
      await Sha256().hash(utf8.encode('taraxacum-topic|$roomId|$roomKey'));
  final hex = digest.bytes
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  return 'taraxacum/${hex.substring(0, 32)}';
}
