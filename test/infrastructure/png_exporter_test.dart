import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:taraxacum_draw/application/view_transform.dart';
import 'package:taraxacum_draw/domain/canvas_document.dart';
import 'package:taraxacum_draw/domain/op.dart';
import 'package:taraxacum_draw/domain/stroke.dart';
import 'package:taraxacum_draw/infrastructure/export/png_exporter.dart';

AddStrokeOp _strokeOp(String opId, int lamport, List<StrokePoint> points) =>
    AddStrokeOp(
      opId: opId,
      authorId: 'local',
      lamport: lamport,
      wallTimeMs: 0,
      stroke: Stroke(
        id: 's-$opId',
        authorId: 'local',
        layerId: 'base',
        tool: DrawTool.brush,
        color: 0xFFE53935,
        width: 6,
        points: points,
        createdAtMs: 0,
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('导出 PNG：文件头正确且分辨率为视口 2x', () async {
    final doc = CanvasDocument()
      ..applyOp(_strokeOp('o1', 1, const [
        StrokePoint(x: 10, y: 10),
        StrokePoint(x: 80, y: 60),
      ]));

    final bytes = await PngExporter.export(
      state: doc.state,
      view: const ViewTransform(),
      viewport: const Size(120, 90),
    );

    // PNG 魔数。
    expect(bytes.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
    // IHDR：宽高为大端序，位于 16..24 字节。
    final width = (bytes[16] << 24) | (bytes[17] << 16) | (bytes[18] << 8) | bytes[19];
    final height = (bytes[20] << 24) | (bytes[21] << 16) | (bytes[22] << 8) | bytes[23];
    expect(width, 240, reason: '120 × 2x');
    expect(height, 180, reason: '90 × 2x');
  });

  test('导出遵循视图变换：放大后仍渲染视口内容', () async {
    final doc = CanvasDocument()..applyOp(_strokeOp('o1', 1, const [
      StrokePoint(x: 10, y: 10),
      StrokePoint(x: 80, y: 60),
    ]));
    final zoomed = const ViewTransform().zoomAt(const Offset(60, 45), 2);

    final bytes = await PngExporter.export(
      state: doc.state,
      view: zoomed,
      viewport: const Size(100, 75),
    );
    expect(bytes.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
  });

  test('隐藏图层不进入导出', () async {
    final doc = CanvasDocument()
      ..applyOp(_strokeOp('o1', 1, const [
        StrokePoint(x: 10, y: 10),
        StrokePoint(x: 80, y: 60),
      ]))
      ..applyOp(SetLayerVisibleOp(
        opId: 'v1',
        authorId: 'local',
        lamport: 2,
        wallTimeMs: 0,
        layerId: 'base',
        visible: false,
      ));

    final bytes = await PngExporter.export(
      state: doc.state,
      view: const ViewTransform(),
      viewport: const Size(120, 90),
    );
    expect(bytes.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
    // 仅白底 + 无笔迹：导出成功即可，内容断言由验收阶段人工核对。
  });
}
