import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'package:taraxacum_draw/domain/ids.dart';

/// 本地身份（design.md D5）：无账号，首次启动生成并持久化。
class LocalIdentity {
  const LocalIdentity({
    required this.peerId,
    required this.name,
    required this.color,
  });

  final PeerId peerId;
  final String name;

  /// 身份颜色 0xRRGGBBAA（光标/成员列表/聊天共用，会话内稳定）。
  final int color;
}

/// 身份存储抽象（生产 SharedPreferences / 测试内存实现）。
abstract class IdentityStorage {
  Future<Map<String, Object?>> read();
  Future<void> write(Map<String, Object?> values);
}

class SharedPreferencesIdentityStorage implements IdentityStorage {
  static const String _prefix = 'identity.';

  @override
  Future<Map<String, Object?>> read() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys().where((k) => k.startsWith(_prefix));
    return {
      for (final key in keys)
        key.substring(_prefix.length): prefs.get(key),
    };
  }

  @override
  Future<void> write(Map<String, Object?> values) async {
    final prefs = await SharedPreferences.getInstance();
    for (final entry in values.entries) {
      final key = '$_prefix${entry.key}';
      final value = entry.value;
      if (value is String) {
        await prefs.setString(key, value);
      } else if (value is int) {
        await prefs.setInt(key, value);
      }
    }
  }
}

/// 测试用内存存储。
class InMemoryIdentityStorage implements IdentityStorage {
  Map<String, Object?> _data = {};

  @override
  Future<Map<String, Object?>> read() async => Map.of(_data);

  @override
  Future<void> write(Map<String, Object?> values) async {
    _data = Map.of(values);
  }
}

/// 身份服务：读取或创建本地身份。
class IdentityService {
  IdentityService({IdentityStorage? storage, this.defaultName = '画友'})
      : _storage = storage ?? SharedPreferencesIdentityStorage();

  final IdentityStorage _storage;
  final String defaultName;

  LocalIdentity? _cached;

  /// 读取持久身份；不存在则生成（peerId/昵称/颜色一并持久化）。
  Future<LocalIdentity> ensureIdentity() async {
    final cached = _cached;
    if (cached != null) return cached;

    final saved = await _storage.read();
    final peerId = saved['peerId'] as String?;
    final name = saved['name'] as String?;
    final color = saved['color'] as int?;
    if (peerId != null && name != null && color != null) {
      return _cached =
          LocalIdentity(peerId: peerId, name: name, color: color);
    }

    final newPeerId = const Uuid().v4();
    final identity = LocalIdentity(
      peerId: newPeerId,
      name: '$defaultName-${newPeerId.substring(0, 4)}',
      color: identityColor(newPeerId),
    );
    await _storage.write({
      'peerId': identity.peerId,
      'name': identity.name,
      'color': identity.color,
    });
    return _cached = identity;
  }

  /// 修改昵称并持久化（颜色与 peerId 不变）。
  Future<LocalIdentity> rename(String name) async {
    final identity = await ensureIdentity();
    final updated = LocalIdentity(
      peerId: identity.peerId,
      name: name,
      color: identity.color,
    );
    await _storage.write({'name': name});
    return _cached = updated;
  }
}

/// 身份颜色：peerId 哈希 × 黄金角(137.508°)，相邻身份色相错开，
/// 群体分布均匀（collaboration-presence 规格的颜色区分度要求）。
int identityColor(String peerId) =>
    _hslToRgb(hueForHash(peerId.hashCode), 0.62, 0.52);

/// 标准 HSL→RGB（纯数学，避免依赖 dart:ui 便于领域层测试）。
int _hslToRgb(double hue, double saturation, double lightness) {
  final chroma = (1 - (2 * lightness - 1).abs()) * saturation;
  final hp = hue / 60;
  final x = chroma * (1 - (hp % 2 - 1).abs());
  double r = 0, g = 0, b = 0;
  if (hp < 1) {
    r = chroma;
    g = x;
  } else if (hp < 2) {
    r = x;
    g = chroma;
  } else if (hp < 3) {
    g = chroma;
    b = x;
  } else if (hp < 4) {
    g = x;
    b = chroma;
  } else if (hp < 5) {
    r = x;
    b = chroma;
  } else {
    r = chroma;
    b = x;
  }
  final m = lightness - chroma / 2;
  int channel(double v) => ((v + m) * 255).round().clamp(0, 255);
  return 0xFF000000 | (channel(r) << 16) | (channel(g) << 8) | channel(b);
}

/// 供测试的色相计算（0..360）。
double hueForHash(int hash) {
  final scaled = (hash % 100000) * 137.508 % 360;
  return scaled < 0 ? scaled + 360 : scaled;
}
