import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:taraxacum_draw/application/canvas_controller.dart';

void main() {
  late ProviderContainer container;
  late CanvasController controller;

  setUp(() {
    container = ProviderContainer();
    addTearDown(container.dispose);
    controller = container.read(canvasProvider.notifier);
  });

  void draw(String id) {
    controller.onPointerDown(0, 0, null);
    controller.onPointerMove(10, 10, null);
    controller.onPointerUp();
  }

  int strokeCount() => container
      .read(canvasProvider)
      .document
      .strokesOf('base')
      .length;

  test('连续撤销与重做', () {
    draw('a');
    draw('b');
    draw('c');
    expect(strokeCount(), 3);

    controller.undo();
    controller.undo();
    expect(strokeCount(), 1);

    controller.redo();
    controller.redo();
    expect(strokeCount(), 3, reason: '两次重做恢复两笔');

    controller.undo();
    expect(strokeCount(), 2);
  });

  test('无可撤销/重做时为安全空操作', () {
    controller.undo();
    controller.redo();
    expect(strokeCount(), 0);
  });

  test('清空画布可撤销（图层结构保留）', () {
    draw('a');
    draw('b');
    controller.addLayer();
    controller.clearCanvas();

    final after = container.read(canvasProvider).document;
    expect(after.strokesOf('base'), isEmpty);
    expect(after.state.layers.length, 2, reason: '清空只清笔迹，保留图层');

    controller.undo();
    final restored = container.read(canvasProvider).document;
    expect(restored.strokesOf('base').length, 2, reason: '撤销清空恢复全部笔迹');
  });

  test('撤销/重做覆盖图层操作', () {
    controller.addLayer();
    expect(container.read(canvasProvider).document.state.layers.length, 2);

    controller.undo();
    expect(container.read(canvasProvider).document.state.layers.length, 1);

    controller.redo();
    expect(container.read(canvasProvider).document.state.layers.length, 2);
  });

  test('新建图层后的绘制各自独立撤销', () {
    draw('a');
    controller.addLayer();
    final topLayer = container.read(canvasProvider).activeLayerId;
    controller.setActiveLayer(topLayer);
    draw('b');

    controller.undo(); // 撤销 top 层那笔
    expect(
      container.read(canvasProvider).document.strokesOf(topLayer),
      isEmpty,
    );
    expect(strokeCount(), 1, reason: 'base 层笔画不受影响');
  });
}
