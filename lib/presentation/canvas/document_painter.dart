import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'package:taraxacum_draw/domain/canvas_document.dart';
import 'package:taraxacum_draw/domain/stroke.dart';
import 'package:taraxacum_draw/infrastructure/render/layer_raster_cache.dart';

/// 画布内容绘制器：自底向上逐层 saveLayer 绘制缓存画面，
/// 进行中的笔画画在其目标层内部（橡皮 dstOut 只影响该层）。
class DocumentPainter extends CustomPainter {
  DocumentPainter({
    required this.cache,
    required this.state,
    required this.activeStroke,
  });

  final LayerRasterCache cache;
  final CanvasState state;
  final Stroke? activeStroke;

  @override
  void paint(ui.Canvas canvas, ui.Size size) {
    // 画板底色。
    canvas.drawRect(
      Offset.zero & size,
      ui.Paint()..color = const ui.Color(0xFFFFFFFF),
    );

    final seen = <String>{};
    for (final layer in state.layers) {
      if (!layer.visible) continue;
      seen.add(layer.id);

      final strokes = state.strokesByLayer[layer.id] ?? const <Stroke>[];
      // saveLayer 使橡皮的 dstOut 只作用于本层。
      canvas.saveLayer(Offset.zero & size, ui.Paint());
      final picture = cache.pictureFor(layer.id, strokes);
      if (picture != null) canvas.drawPicture(picture);
      final active = activeStroke;
      if (active != null && active.layerId == layer.id) {
        LayerRasterCache.drawStroke(canvas, active);
      }
      canvas.restore();
    }

    // 清理已删除图层的缓存。
    for (final id in cache.keys.where((id) => !seen.contains(id)).toList()) {
      cache.drop(id);
    }
  }

  @override
  bool shouldRepaint(DocumentPainter oldDelegate) =>
      oldDelegate.state != state ||
      !identical(oldDelegate.activeStroke, activeStroke);
}
