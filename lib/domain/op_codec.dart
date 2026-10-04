import 'dart:convert';
import 'dart:typed_data';

import 'package:taraxacum_draw/domain/layer.dart';
import 'package:taraxacum_draw/domain/op.dart';
import 'package:taraxacum_draw/domain/stroke.dart';

/// Op 二进制编解码（task 5.1）。
///
/// 布局（大端）：kind(1) | opId(2+str) | author(2+str) | lamport(8)
/// | wallTime(8) | kind 专属载荷。字符串 = len(2)+utf8；点 = f32×3。
/// 任何长度不一致抛 FormatException。
class OpCodec {
  static Uint8List encode(Op op) {
    final builder = BytesBuilder(copy: false);
    builder.add(Uint8List.fromList([op.kind.index]));
    _writeStr(builder, op.opId);
    _writeStr(builder, op.authorId);
    final fixed = ByteData(16)
      ..setUint64(0, op.lamport, Endian.big)
      ..setInt64(8, op.wallTimeMs, Endian.big);
    builder.add(fixed.buffer.asUint8List());

    switch (op) {
      case AddStrokeOp(:final stroke):
        _writeStr(builder, stroke.id);
        _writeStr(builder, stroke.layerId);
        builder.add(Uint8List.fromList([
          stroke.tool.index,
          (stroke.color >> 24) & 0xFF,
          (stroke.color >> 16) & 0xFF,
          (stroke.color >> 8) & 0xFF,
          stroke.color & 0xFF,
        ]));
        final width = ByteData(8)..setFloat64(0, stroke.width, Endian.big);
        builder.add(width.buffer.asUint8List());
        final count = ByteData(4)
          ..setUint32(0, stroke.points.length, Endian.big);
        builder.add(count.buffer.asUint8List());
        final points = ByteData(stroke.points.length * 12);
        for (var i = 0; i < stroke.points.length; i++) {
          points
            ..setFloat32(i * 12, stroke.points[i].x, Endian.big)
            ..setFloat32(i * 12 + 4, stroke.points[i].y, Endian.big)
            ..setFloat32(i * 12 + 8, stroke.points[i].pressure ?? 0, Endian.big);
        }
        builder.add(points.buffer.asUint8List());
      case UndoOp(:final undoneOpId):
        _writeStr(builder, undoneOpId);
      case ClearCanvasOp():
        break;
      case AddLayerOp(:final layer):
        _writeLayer(builder, layer);
      case RemoveLayerOp(:final layerId):
        _writeStr(builder, layerId);
      case MoveLayerOp(:final layerId, :final newOrder):
        _writeStr(builder, layerId);
        final order = ByteData(4)..setInt32(0, newOrder, Endian.big);
        builder.add(order.buffer.asUint8List());
      case SetLayerVisibleOp(:final layerId, :final visible):
        _writeStr(builder, layerId);
        builder.add(Uint8List.fromList([visible ? 1 : 0]));
    }
    return builder.toBytes();
  }

  static Op decode(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    var o = 0;
    final kindIndex = data.getUint8(o);
    if (kindIndex >= OpKind.values.length) {
      throw FormatException('未知 op kind: $kindIndex');
    }
    o += 1;
    final opId = _readStr(bytes, data, o);
    o += 2 + opId.$2;
    final author = _readStr(bytes, data, o);
    o += 2 + author.$2;
    final lamport = data.getUint64(o, Endian.big);
    final wallTime = data.getInt64(o + 8, Endian.big);
    o += 16;

    Op op;
    switch (OpKind.values[kindIndex]) {
      case OpKind.addStroke:
        final strokeId = _readStr(bytes, data, o);
        o += 2 + strokeId.$2;
        final layerId = _readStr(bytes, data, o);
        o += 2 + layerId.$2;
        final tool = DrawTool.values[(data.getUint8(o)).clamp(0, 1)];
        final color = data.getUint32(o + 1, Endian.big);
        final width = data.getFloat64(o + 5, Endian.big);
        final count = data.getUint32(o + 13, Endian.big);
        o += 17;
        final points = <StrokePoint>[];
        final pointsData = ByteData.sublistView(bytes, o);
        for (var i = 0; i < count; i++) {
          final pressure = pointsData.getFloat32(i * 12 + 8, Endian.big);
          points.add(StrokePoint(
            x: pointsData.getFloat32(i * 12, Endian.big),
            y: pointsData.getFloat32(i * 12 + 4, Endian.big),
            pressure: pressure == 0 ? null : pressure,
          ));
        }
        o += count * 12;
        op = AddStrokeOp(
          opId: opId.$1,
          authorId: author.$1,
          lamport: lamport,
          wallTimeMs: wallTime,
          stroke: Stroke(
            id: strokeId.$1,
            authorId: author.$1,
            layerId: layerId.$1,
            tool: tool,
            color: color,
            width: width,
            points: points,
            createdAtMs: wallTime,
          ),
        );
      case OpKind.undo:
        final target = _readStr(bytes, data, o);
        op = UndoOp(
          opId: opId.$1,
          authorId: author.$1,
          lamport: lamport,
          wallTimeMs: wallTime,
          undoneOpId: target.$1,
        );
      case OpKind.clearCanvas:
        op = ClearCanvasOp(
          opId: opId.$1,
          authorId: author.$1,
          lamport: lamport,
          wallTimeMs: wallTime,
        );
      case OpKind.addLayer:
        final pair = _readLayer(bytes, data, o);
        op = AddLayerOp(
          opId: opId.$1,
          authorId: author.$1,
          lamport: lamport,
          wallTimeMs: wallTime,
          layer: pair.$1,
        );
      case OpKind.removeLayer:
        final layerId = _readStr(bytes, data, o);
        op = RemoveLayerOp(
          opId: opId.$1,
          authorId: author.$1,
          lamport: lamport,
          wallTimeMs: wallTime,
          layerId: layerId.$1,
        );
      case OpKind.moveLayer:
        final layerId = _readStr(bytes, data, o);
        o += 2 + layerId.$2;
        final order = data.getInt32(o, Endian.big);
        op = MoveLayerOp(
          opId: opId.$1,
          authorId: author.$1,
          lamport: lamport,
          wallTimeMs: wallTime,
          layerId: layerId.$1,
          newOrder: order,
        );
      case OpKind.setLayerVisible:
        final layerId = _readStr(bytes, data, o);
        o += 2 + layerId.$2;
        final visible = data.getUint8(o) == 1;
        op = SetLayerVisibleOp(
          opId: opId.$1,
          authorId: author.$1,
          lamport: lamport,
          wallTimeMs: wallTime,
          layerId: layerId.$1,
          visible: visible,
        );
    }
    return op;
  }

  static void _writeStr(BytesBuilder builder, String s) {
    final bytes = utf8.encode(s);
    if (bytes.length > 0xFFFF) throw FormatException('字符串过长');
    final len = ByteData(2)..setUint16(0, bytes.length, Endian.big);
    builder.add(len.buffer.asUint8List());
    builder.add(bytes);
  }

  static (String, int) _readStr(
      Uint8List bytes, ByteData data, int offset) {
    final length = data.getUint16(offset, Endian.big);
    final value = utf8.decode(bytes.sublist(offset + 2, offset + 2 + length));
    return (value, length);
  }

  static void _writeLayer(BytesBuilder builder, Layer layer) {
    _writeStr(builder, layer.id);
    _writeStr(builder, layer.name);
    final rest = ByteData(5)
      ..setInt32(0, layer.order, Endian.big)
      ..setUint8(4, layer.visible ? 1 : 0);
    builder.add(rest.buffer.asUint8List());
  }

  static (Layer, int) _readLayer(Uint8List bytes, ByteData data, int offset) {
    final id = _readStr(bytes, data, offset);
    var o = offset + 2 + id.$2;
    final name = _readStr(bytes, data, o);
    o += 2 + name.$2;
    final layer = Layer(
      id: id.$1,
      name: name.$1,
      order: data.getInt32(o, Endian.big),
      visible: data.getUint8(o + 4) == 1,
    );
    return (layer, o + 5);
  }
}
