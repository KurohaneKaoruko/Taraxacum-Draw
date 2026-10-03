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

  int addStrokeAt(String layerId) {
    controller.setActiveLayer(layerId);
    controller.onPointerDown(0, 0, null);
    controller.onPointerMove(40, 40, null);
    controller.onPointerUp();
    return container
        .read(canvasProvider)
        .document
        .strokesOf(layerId)
        .length;
  }

  test('新建图层：命名、排序、自动选中', () {
    controller.addLayer();
    final ui = container.read(canvasProvider);
    final layers = ui.document.state.layers;
    expect(layers.length, 2);
    expect(layers.last.order, greaterThan(layers.first.order));
    expect(ui.activeLayerId, layers.last.id, reason: '新图层应自动成为当前层');
  });

  test('新图层上绘制与遮挡关系', () {
    controller.addLayer();
    final base = container.read(canvasProvider).document.state.layers.first.id;
    final top = container.read(canvasProvider).document.state.layers.last.id;

    expect(addStrokeAt(base), 1);
    expect(addStrokeAt(top), 1);

    final doc = container.read(canvasProvider).document;
    expect(doc.strokesOf(base).length, 1);
    expect(doc.strokesOf(top).length, 1);
  });

  test('上移/下移交换叠放顺序', () {
    controller.addLayer();
    final layers = container.read(canvasProvider).document.state.layers;
    final base = layers.first, top = layers.last;

    controller.moveLayer(top.id, towardTop: false); // 顶层下移
    final after = container.read(canvasProvider).document.state.layers;
    expect(after.first.id, top.id);
    expect(after.last.id, base.id);
  });

  test('显隐切换', () {
    final base = container.read(canvasProvider).document.state.layers.first;
    expect(base.visible, isTrue);
    controller.toggleLayerVisible(base.id);
    expect(
      container.read(canvasProvider).document.state.layers.first.visible,
      isFalse,
    );
  });

  test('删除图层：笔迹一并消失、当前层回退、撤销恢复、最后一级保护', () {
    controller.addLayer();
    final layers = container.read(canvasProvider).document.state.layers;
    final base = layers.first, top = layers.last;
    addStrokeAt(top.id);
    expect(container.read(canvasProvider).activeLayerId, top.id);

    // 两层时删除顶层：允许，笔迹消失，当前层回退到 base。
    controller.removeLayer(top.id);
    final after = container.read(canvasProvider).document;
    expect(after.state.layers.map((l) => l.id), [base.id]);
    expect(after.strokesOf(top.id), isEmpty, reason: '随图层删除而消失');
    expect(container.read(canvasProvider).activeLayerId, base.id,
        reason: '当前层被删后回退到存活层');

    // 撤销删除：图层与笔迹恢复。
    controller.undo();
    final restored = container.read(canvasProvider).document;
    expect(restored.state.layers.length, 2);
    expect(restored.strokesOf(top.id).length, 1, reason: '撤销删除后笔迹恢复');

    // 只剩一层时禁止删除。
    controller.removeLayer(top.id); // 2 → 1
    final only = container.read(canvasProvider).document.state.layers.single;
    controller.removeLayer(only.id);
    expect(container.read(canvasProvider).document.state.layers.length, 1);
  });

  test('图层操作整体可撤销（新建/排序）', () {
    controller.addLayer();
    final layers = container.read(canvasProvider).document.state.layers;
    final base = layers.first, top = layers.last;

    controller.moveLayer(top.id, towardTop: false);
    expect(container.read(canvasProvider).document.state.layers.first.id, top.id);

    controller.undo(); // 撤销第二条 MoveLayerOp
    controller.undo(); // 撤销第一条 MoveLayerOp
    final restored = container.read(canvasProvider).document.state.layers;
    expect(restored.first.id, base.id);
    expect(restored.last.id, top.id);

    controller.undo(); // 撤销新建图层
    expect(container.read(canvasProvider).document.state.layers.length, 1);
  });
}
