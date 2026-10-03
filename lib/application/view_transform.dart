import 'dart:ui';

/// 画布视图变换：屏幕坐标 = 画布坐标 × scale + offset。
///
/// 纯数学类，便于单元测试坐标映射（task 2.5 验证点）。
class ViewTransform {
  const ViewTransform({this.scale = 1.0, this.offset = Offset.zero});

  static const double minScale = 0.1;
  static const double maxScale = 10;

  final double scale;
  final Offset offset;

  /// 屏幕坐标 → 画布逻辑坐标。
  Offset toCanvas(Offset screen) => (screen - offset) / scale;

  /// 画布逻辑坐标 → 屏幕坐标。
  Offset toScreen(Offset canvas) => canvas * scale + offset;

  /// 以屏幕上的 [focal] 为焦点缩放 [factor] 倍，焦点下的画布点保持不动。
  ViewTransform zoomAt(Offset focal, double factor,
      {double min = minScale, double max = maxScale}) {
    final target = (scale * factor).clamp(min, max).toDouble();
    if (target == scale) return this;
    final ratio = target / scale;
    return ViewTransform(
      scale: target,
      offset: focal - (focal - offset) * ratio,
    );
  }

  ViewTransform panBy(Offset delta) =>
      ViewTransform(scale: scale, offset: offset + delta);

  @override
  bool operator ==(Object other) =>
      other is ViewTransform && other.scale == scale && other.offset == offset;

  @override
  int get hashCode => Object.hash(scale, offset);
}
