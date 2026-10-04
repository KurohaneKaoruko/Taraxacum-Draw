import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:taraxacum_draw/application/view_transform.dart';
import 'package:taraxacum_draw/domain/canvas_document.dart';
import 'package:taraxacum_draw/domain/stroke.dart';
import 'package:taraxacum_draw/infrastructure/render/layer_raster_cache.dart';

/// 画布 PNG 导出（design.md D8）。
///
/// 导出当前视口所见内容（与显示一致、仅可见图层、不含界面元素），
/// 分辨率 = 视口尺寸 × pixelRatio（默认 2x）。
class PngExporter {
  static Future<Uint8List> export({
    required CanvasState state,
    required ViewTransform view,
    required ui.Size viewport,
    int pixelRatio = 2,
  }) async {
    final ratio = pixelRatio.toDouble();
    final width = (viewport.width * ratio).round();
    final height = (viewport.height * ratio).round();

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);

    // 白底（像素空间）。
    canvas.drawRect(
      ui.Offset.zero & ui.Size(width.toDouble(), height.toDouble()),
      ui.Paint()..color = const ui.Color(0xFFFFFFFF),
    );

    // 与 DocumentPainter 相同的内容变换，整体放大 ratio。
    canvas.scale(ratio, ratio);
    canvas.translate(view.offset.dx, view.offset.dy);
    canvas.scale(view.scale, view.scale);

    for (final layer in state.layers) {
      if (!layer.visible) continue;
      final strokes = state.strokesByLayer[layer.id] ?? const <Stroke>[];
      canvas.saveLayer(null, ui.Paint());
      final picture = LayerRasterCache.recordStrokes(strokes);
      canvas.drawPicture(picture);
      picture.dispose();
      canvas.restore();
    }

    final picture = recorder.endRecording();
    final image = await picture.toImage(width, height);
    picture.dispose();
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data!.buffer.asUint8List();
  }
}
