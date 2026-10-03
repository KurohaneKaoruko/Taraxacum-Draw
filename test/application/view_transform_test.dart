import 'package:flutter_test/flutter_test.dart';
import 'package:taraxacum_draw/application/view_transform.dart';

void main() {
  group('ViewTransform 坐标映射', () {
    test('缩放为 1 时恒等映射', () {
      const t = ViewTransform();
      const p = Offset(123.4, -56.7);
      expect(t.toCanvas(p), p);
      expect(t.toScreen(p), p);
    });

    test('toCanvas 与 toScreen 互逆（含缩放与平移）', () {
      const t = ViewTransform(scale: 2.5, offset: Offset(40, -30));
      const screen = Offset(210, 70);
      final canvas = t.toCanvas(screen);
      expect(t.toScreen(canvas), screen);
    });

    test('同一画布点在不同变换下映射一致', () {
      const canvasPoint = Offset(55, 66);
      const a = ViewTransform();
      const b = ViewTransform(scale: 1.75, offset: Offset(-120, 88));
      expect(b.toScreen(canvasPoint), isNot(a.toScreen(canvasPoint)));
      // 各自逆映射回同一画布点。
      expect(a.toCanvas(a.toScreen(canvasPoint)), canvasPoint);
      expect(b.toCanvas(b.toScreen(canvasPoint)), canvasPoint);
    });
  });

  group('zoomAt', () {
    test('焦点下的画布点缩放前后保持不动', () {
      var t = const ViewTransform(offset: Offset(100, 50));
      const focal = Offset(300, 200);
      final canvasAtFocal = t.toCanvas(focal);

      t = t.zoomAt(focal, 1.6);
      expect(t.toCanvas(focal), canvasAtFocal, reason: '焦点映射的画布点不变');

      t = t.zoomAt(focal, 0.5);
      expect(t.toCanvas(focal), canvasAtFocal);
    });

    test('缩放倍数被钳制在范围内', () {
      var t = const ViewTransform();
      t = t.zoomAt(Offset.zero, 1e6);
      expect(t.scale, ViewTransform.maxScale);
      t = t.zoomAt(Offset.zero, 1e-6);
      expect(t.scale, ViewTransform.minScale);
    });

    test('factor 为 1 时不产生变化', () {
      const t = ViewTransform(scale: 2, offset: Offset(9, 9));
      expect(t.zoomAt(const Offset(1, 1), 1.0), same(t));
    });
  });

  group('panBy', () {
    test('平移不改变缩放', () {
      const t = ViewTransform(scale: 3, offset: Offset(1, 2));
      final panned = t.panBy(const Offset(10, -5));
      expect(panned.scale, 3);
      expect(panned.offset, const Offset(11, -3));
    });
  });
}
