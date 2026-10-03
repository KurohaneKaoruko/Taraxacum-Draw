import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:taraxacum_draw/application/canvas_controller.dart';

/// 图层面板（底部弹层）：列表自顶向底显示，点选切换当前层。
class LayerPanel extends ConsumerWidget {
  const LayerPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ui = ref.watch(canvasProvider);
    final controller = ref.read(canvasProvider.notifier);
    final layers = ui.document.state.layers.reversed.toList(); // 顶 → 底

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Text('图层', style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                FilledButton.tonalIcon(
                  onPressed: controller.addLayer,
                  icon: const Icon(Icons.add),
                  label: const Text('新建'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: layers.length,
                itemBuilder: (context, i) {
                  final layer = layers[i];
                  final active = layer.id == ui.activeLayerId;
                  return ListTile(
                    leading: IconButton(
                      tooltip: layer.visible ? '隐藏' : '显示',
                      icon: Icon(
                        layer.visible ? Icons.visibility : Icons.visibility_off,
                      ),
                      onPressed: () => controller.toggleLayerVisible(layer.id),
                    ),
                    title: Text(
                      layer.name,
                      style: active
                          ? TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Theme.of(context).colorScheme.primary,
                            )
                          : null,
                    ),
                    selected: active,
                    onTap: () => controller.setActiveLayer(layer.id),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: '上移',
                          icon: const Icon(Icons.arrow_upward),
                          onPressed: i > 0
                              ? () =>
                                  controller.moveLayer(layer.id, towardTop: true)
                              : null,
                        ),
                        IconButton(
                          tooltip: '下移',
                          icon: const Icon(Icons.arrow_downward),
                          onPressed: i < layers.length - 1
                              ? () => controller.moveLayer(layer.id,
                                  towardTop: false)
                              : null,
                        ),
                        IconButton(
                          tooltip: '删除',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: layers.length > 1
                              ? () => controller.removeLayer(layer.id)
                              : null,
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
