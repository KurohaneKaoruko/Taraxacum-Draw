import 'dart:ui' as ui;

import 'package:taraxacum_draw/domain/stroke.dart';

/// 单图层缓存的已录制画面。
class _LayerEntry {
  ui.Picture? picture;
  int strokeCount = -1;
  Stroke? lastStroke;
}

/// 每图层一张离屏 [ui.Picture] 的栅格缓存（design.md D2）。
///
/// 只有当图层的笔迹列表变化（新增/重放重建）时才重新录制该层，
/// 进行中的笔画不进入缓存，由上层直接绘制。
/// 注：重录代价为 O(该层笔迹数)，后续可用分块缓存进一步优化。
class LayerRasterCache {
  final Map<String, _LayerEntry> _entries = {};

  /// 返回该图层的缓存画面；内容未变化时直接复用。
  ui.Picture? pictureFor(String layerId, List<Stroke> strokes) {
    final entry = _entries.putIfAbsent(layerId, _LayerEntry.new);
    final unchanged = entry.strokeCount == strokes.length &&
        identical(entry.lastStroke, strokes.lastOrNull) &&
        entry.picture != null;
    if (unchanged) return entry.picture;

    entry.picture?.dispose();
    entry.picture = _record(strokes);
    entry.strokeCount = strokes.length;
    entry.lastStroke = strokes.lastOrNull;
    return entry.picture;
  }

  /// 图层被删除时释放对应缓存。
  void drop(String layerId) {
    _entries.remove(layerId)?.picture?.dispose();
  }

  /// 当前缓存的所有图层 id（用于比对文档，回收已删除图层的缓存）。
  Iterable<String> get keys => _entries.keys;

  ui.Picture _record(List<Stroke> strokes) => recordStrokes(strokes);

  /// 将一组笔迹录制为离屏画面（缓存与 PNG 导出共用）。
  static ui.Picture recordStrokes(List<Stroke> strokes) {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    for (final stroke in strokes) {
      drawStroke(canvas, stroke);
    }
    return recorder.endRecording();
  }

  /// 绘制一条笔迹（缓存录制与进行中笔画共用）。
  ///
  /// 橡皮使用 [ui.BlendMode.dstOut]，必须在所在图层的 saveLayer 内调用，
  /// 才能只擦除本图层内容而不影响其他图层。
  static void drawStroke(ui.Canvas canvas, Stroke stroke) {
    final points = stroke.points;
    if (points.isEmpty) return;

    final paint = ui.Paint()
      ..color = ui.Color(stroke.color)
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = stroke.width
      ..strokeCap = ui.StrokeCap.round
      ..strokeJoin = ui.StrokeJoin.round
      ..isAntiAlias = true;
    if (stroke.tool == DrawTool.eraser) paint.blendMode = ui.BlendMode.dstOut;

    if (points.length == 1) {
      // 单点：画圆点，保证点击也能留下痕迹。
      final dot = ui.Paint.from(paint)..style = ui.PaintingStyle.fill;
      canvas.drawCircle(
        ui.Offset(points.first.x, points.first.y),
        stroke.width / 2,
        dot,
      );
      return;
    }
    canvas.drawPath(smoothPath(points), paint);
  }

  /// 中点二次贝塞尔平滑：以相邻点中点为端点、原点为控制点。
  static ui.Path smoothPath(List<StrokePoint> points) {
    final path = ui.Path()..moveTo(points.first.x, points.first.y);
    for (var i = 1; i < points.length - 1; i++) {
      final mid = ui.Offset(
        (points[i].x + points[i + 1].x) / 2,
        (points[i].y + points[i + 1].y) / 2,
      );
      path.quadraticBezierTo(points[i].x, points[i].y, mid.dx, mid.dy);
    }
    path.lineTo(points.last.x, points.last.y);
    return path;
  }
}
