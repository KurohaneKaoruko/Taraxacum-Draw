import 'package:flutter_test/flutter_test.dart';
import 'package:taraxacum_draw/application/identity.dart';

void main() {
  group('IdentityService', () {
    test('首次生成身份并持久化', () async {
      final storage = InMemoryIdentityStorage();
      final service = IdentityService(storage: storage);
      final identity = await service.ensureIdentity();

      expect(identity.peerId, isNotEmpty);
      expect(identity.name, startsWith('画友-'));
      expect(identity.color, greaterThan(0));
      expect(
        (await storage.read())['peerId'],
        identity.peerId,
        reason: '身份应写入存储',
      );
    });

    test('重启（新服务实例）后身份不变', () async {
      final storage = InMemoryIdentityStorage();
      final first =
          await IdentityService(storage: storage).ensureIdentity();
      final second =
          await IdentityService(storage: storage).ensureIdentity();

      expect(second.peerId, first.peerId, reason: '重启不得重新生成身份');
      expect(second.name, first.name);
      expect(second.color, first.color);
    });

    test('改名持久化且 peerId/颜色不变', () async {
      final storage = InMemoryIdentityStorage();
      final service = IdentityService(storage: storage);
      final before = await service.ensureIdentity();
      final renamed = await service.rename('蒲公英');

      expect(renamed.name, '蒲公英');
      expect(renamed.peerId, before.peerId);
      expect(renamed.color, before.color);
    });
  });

  group('身份颜色', () {
    test('确定性：同一 peerId 恒得同一颜色', () {
      expect(identityColor('peer-abc'), identityColor('peer-abc'));
      expect(hueForHash('peer-abc'.hashCode), hueForHash('peer-abc'.hashCode));
    });

    test('16 个身份颜色全部互异', () {
      final colors = <int>{};
      for (var i = 0; i < 16; i++) {
        colors.add(identityColor('peer-uuid-$i-xxxxxxxx'));
      }
      expect(colors.length, 16, reason: '身份颜色必须两两可区分');
    });

    test('黄金角色分布：顺序哈希产生接近均匀的色相序列', () {
      // 黄金角 137.508° 保证连续索引的色相间隔约 137.5° 或 222.5°，
      // 均大于 90°，满足"相邻身份高区分度"。
      final hues = [
        for (var i = 0; i < 8; i++) hueForHash(i * 7919),
      ];
      for (final hue in hues) {
        expect(hue, greaterThanOrEqualTo(0));
        expect(hue, lessThan(360));
      }
      // 序列中至少覆盖 180° 以上的色相跨度。
      final sorted = [...hues]..sort();
      final span = sorted.last - sorted.first;
      expect(span, greaterThan(180),
          reason: '采样色相跨度应显著覆盖色环');
    });
  });
}
