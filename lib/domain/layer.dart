import 'ids.dart';

/// 画布图层（房间内所有成员共享同一组图层，见 proposal 假设）。
class Layer {
  const Layer({
    required this.id,
    required this.name,
    required this.order,
    this.visible = true,
  });

  final LayerId id;
  final String name;

  /// 叠放顺序，值大者在上层。
  final int order;

  final bool visible;

  Layer copyWith({String? name, int? order, bool? visible}) => Layer(
        id: id,
        name: name ?? this.name,
        order: order ?? this.order,
        visible: visible ?? this.visible,
      );
}
