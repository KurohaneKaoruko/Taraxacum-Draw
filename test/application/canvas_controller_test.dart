import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:taraxacum_draw/application/canvas_controller.dart';
import 'package:taraxacum_draw/domain/stroke.dart';

void main() {
  test('指针按下-移动-抬起 生成一笔并写入文档', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final controller = container.read(canvasProvider.notifier);
    controller.onPointerDown(0, 0, null);
    controller.onPointerMove(10, 10, null);
    controller.onPointerMove(20, 5, null);
    controller.onPointerUp();

    final ui = container.read(canvasProvider);
    expect(ui.document.strokesOf('base').length, 1);
    final stroke = ui.document.strokesOf('base').single;
    expect(stroke.points.length, 3);
    expect(stroke.tool, DrawTool.brush);
    expect(ui.inProgress, isNull, reason: '定稿后进行中笔画应清空');
  });

  test('极小位移的移动点被过滤', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final controller = container.read(canvasProvider.notifier);
    controller.onPointerDown(0, 0, null);
    controller.onPointerMove(0.5, 0.5, null); // 距离 < 1，应被忽略
    controller.onPointerMove(30, 30, null);
    controller.onPointerUp();

    final stroke = container.read(canvasProvider).document.strokesOf('base').single;
    expect(stroke.points.length, 2);
  });

  test('橡皮工具与撤销集成', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final controller = container.read(canvasProvider.notifier);
    controller.onPointerDown(1, 1, null);
    controller.onPointerMove(50, 50, null);
    controller.onPointerUp();

    controller.setTool(DrawTool.eraser);
    controller.onPointerDown(50, 50, null);
    controller.onPointerMove(60, 60, null);
    controller.onPointerUp();

    final doc = container.read(canvasProvider).document;
    expect(doc.strokesOf('base').length, 2);
    expect(doc.strokesOf('base').last.tool, DrawTool.eraser);

    controller.undo();
    expect(doc.strokesOf('base').length, 1, reason: '撤销应移除橡皮笔画');

    controller.undo();
    expect(doc.strokesOf('base'), isEmpty, reason: '再次撤销应移除画笔笔画');
  });

  test('指针取消丢弃进行中笔画', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final controller = container.read(canvasProvider.notifier);
    controller.onPointerDown(0, 0, null);
    controller.onPointerMove(10, 10, null);
    controller.onPointerCancel();

    final ui = container.read(canvasProvider);
    expect(ui.inProgress, isNull);
    expect(ui.document.strokesOf('base'), isEmpty);
  });
}
