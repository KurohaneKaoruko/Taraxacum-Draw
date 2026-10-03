import 'ids.dart';

/// 绘画工具类型。
enum DrawTool { brush, eraser }

/// 笔迹上的一个采样点。
class StrokePoint {
  const StrokePoint({required this.x, required this.y, this.pressure});

  final double x;
  final double y;

  /// 手写笔压力 0.0–1.0；鼠标/触控为 null。
  final double? pressure;

  factory StrokePoint.fromMap(Map<String, Object?> map) => StrokePoint(
        x: (map['x'] as num).toDouble(),
        y: (map['y'] as num).toDouble(),
        pressure: (map['p'] as num?)?.toDouble(),
      );

  Map<String, Object?> toMap() => {
        'x': x,
        'y': y,
        if (pressure != null) 'p': pressure,
      };
}

/// 一条完整笔迹（同步与渲染的最小单位，不可变）。
class Stroke {
  const Stroke({
    required this.id,
    required this.authorId,
    required this.layerId,
    required this.tool,
    required this.color,
    required this.width,
    required this.points,
    required this.createdAtMs,
  });

  final StrokeId id;
  final PeerId authorId;
  final LayerId layerId;
  final DrawTool tool;

  /// 0xRRGGBBAA。
  final int color;

  /// 逻辑坐标下的笔宽（画布坐标系，与视图缩放无关）。
  final double width;

  final List<StrokePoint> points;

  /// 创建时间戳（毫秒），仅用于展示与调试，不参与排序。
  final int createdAtMs;

  int get length => points.length;
}
