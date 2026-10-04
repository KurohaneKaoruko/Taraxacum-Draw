import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'package:taraxacum_draw/application/presence/presence_controller.dart';
import 'package:taraxacum_draw/application/view_transform.dart';
import 'package:taraxacum_draw/domain/canvas_document.dart';
import 'package:taraxacum_draw/domain/stroke.dart';
import 'package:taraxacum_draw/infrastructure/render/layer_raster_cache.dart';

/// 画布内容绘制器：自底向上逐层 saveLayer 绘制缓存画面，
/// 进行中的笔画画在其目标层内部（橡皮 dstOut 只影响该层），
/// 最后在屏幕空间绘制远端光标（恒定大小 + 昵称标签）。
class DocumentPainter extends CustomPainter {
  DocumentPainter({
    required this.cache,
    required this.state,
    required this.view,
    required this.activeStroke,
    this.cursors = const [],
  });

  final LayerRasterCache cache;
  final CanvasState state;
  final ViewTransform view;
  final Stroke? activeStroke;

  /// 远端光标（画布逻辑坐标）。
  final List<RemoteCursor> cursors;

  @override
  void paint(ui.Canvas canvas, ui.Size size) {
    // 画板底色（屏幕空间）。
    canvas.drawRect(
      Offset.zero & size,
      ui.Paint()..color = const ui.Color(0xFFFFFFFF),
    );

    // 视图变换：内容进入画布逻辑坐标系。
    canvas.save();
    canvas.translate(view.offset.dx, view.offset.dy);
    canvas.scale(view.scale, view.scale);

    final seen = <String>{};
    for (final layer in state.layers) {
      if (!layer.visible) continue;
      seen.add(layer.id);

      final strokes = state.strokesByLayer[layer.id] ?? const <Stroke>[];
      // saveLayer 使橡皮的 dstOut 只作用于本层。
      canvas.saveLayer(null, ui.Paint());
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
    canvas.restore();

    // 远端光标（屏幕空间，不随缩放变化大小）。
    for (final cursor in cursors) {
      final pos = view.toScreen(Offset(cursor.x, cursor.y));
      final color = ui.Color(cursor.color);
      canvas.drawCircle(
        pos,
        6,
        ui.Paint()
          ..color = color
          ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 2),
      );
      canvas.drawCircle(
        pos,
        6,
        ui.Paint()
          ..style = ui.PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = const ui.Color(0xFFFFFFFF),
      );
      if (cursor.name.isEmpty) continue;
      final painter = TextPainter(
        text: TextSpan(
          text: cursor.name,
          style: const TextStyle(color: Colors.white, fontSize: 11),
        ),
        textDirection: TextDirection.ltr,
      )
        ..layout();
      final rect = Rect.fromLTWH(pos.dx + 9, pos.dy + 9, painter.width + 8,
          painter.height + 4);
      canvas.drawRRect(
        ui.RRect.fromRectAndRadius(rect, const Radius.circular(4)),
        ui.Paint()..color = color.withAlpha(230),
      );
      painter.paint(canvas, rect.topLeft + const Offset(4, 2));
    }
  }

  @override
  bool shouldRepaint(DocumentPainter oldDelegate) =>
      oldDelegate.state != state ||
      oldDelegate.view != view ||
      !identical(oldDelegate.activeStroke, activeStroke) ||
      !identical(oldDelegate.cursors, cursors);
}
