import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:taraxacum_draw/application/room/room_controller.dart';
import 'package:taraxacum_draw/presentation/room/invite_scan_view.dart';
import 'package:taraxacum_draw/presentation/room/room_page.dart';

/// 首页：身份展示 + 创建/加入房间入口。
class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ui = ref.watch(roomControllerProvider);
    final controller = ref.read(roomControllerProvider.notifier);

    ref.listen<RoomUiState>(roomControllerProvider, (previous, next) {
      if (next.stage == RoomStage.inRoom &&
          previous?.stage != RoomStage.inRoom) {
        Navigator.of(context, rootNavigator: true).pushReplacement(
          MaterialPageRoute<void>(builder: (_) => const RoomPage()),
        );
      }
      if (next.error != null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(next.error!)));
      }
    });

    return Scaffold(
      key: const Key('home_page'),
      appBar: AppBar(
        title: const Text('TaraxacumDraw 蒲公英'),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _IdentityCard(
                name: ui.identity?.name ?? '正在加载身份…',
                color: ui.identity?.color ?? 0xFF888888,
                onRename: (name) async {
                  await ref.read(identityProvider).rename(name);
                  final identity =
                      await ref.read(identityProvider).ensureIdentity();
                  controller.refreshIdentity(identity);
                },
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                key: const Key('create_room'),
                icon: const Icon(Icons.add_circle_outline),
                label: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('创建房间'),
                ),
                onPressed: ui.stage == RoomStage.idle
                    ? () => _promptText(
                          context,
                          title: '创建房间',
                          hint: '房间名称',
                          initial: '蒲公英房间',
                        ).then((name) {
                          if (name != null && name.isNotEmpty) {
                            controller.createRoom(name);
                          }
                        })
                    : null,
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                key: const Key('join_room'),
                icon: const Icon(Icons.group_add_outlined),
                label: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('加入房间（房间号）'),
                ),
                onPressed: ui.stage == RoomStage.idle
                    ? () => _promptText(
                          context,
                          title: '加入房间',
                          hint: '房间号',
                        ).then((roomId) {
                          if (roomId != null && roomId.isNotEmpty) {
                            controller.joinByRoomId(roomId.trim());
                          }
                        })
                    : null,
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                icon: const Icon(Icons.qr_code_scanner),
                label: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('扫描邀请二维码'),
                ),
                onPressed: ui.stage == RoomStage.idle
                    ? () async {
                        final code = await Navigator.of(context).push<String>(
                          MaterialPageRoute(
                            builder: (_) => InviteScanView(
                              onComplete: (code) =>
                                  controller.joinByInviteCode(code),
                            ),
                          ),
                        );
                        if (code != null && code.isNotEmpty) {
                          await controller.joinByInviteCode(code);
                        }
                      }
                    : null,
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                icon: const Icon(Icons.paste),
                label: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('粘贴邀请码'),
                ),
                onPressed: ui.stage == RoomStage.idle
                    ? () => _promptText(
                          context,
                          title: '粘贴邀请码',
                          hint: '粘贴邀请码文本（多帧用换行分隔）',
                          maxLines: 6,
                        ).then((code) {
                          if (code == null || code.trim().isEmpty) return;
                          if (code.contains('TDI|') &&
                              code.trim().split('\n').length > 1) {
                            controller.joinByInviteFrames(
                              code.trim().split('\n').map((l) => l.trim()),
                            );
                          } else {
                            controller.joinByInviteCode(code.trim());
                          }
                        })
                    : null,
              ),
              if (ui.stage == RoomStage.connecting) ...[
                const SizedBox(height: 24),
                const Center(child: CircularProgressIndicator()),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<String?> _promptText(
    BuildContext context, {
    required String title,
    required String hint,
    String? initial,
    int maxLines = 1,
  }) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: maxLines,
          decoration: InputDecoration(hintText: hint),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }
}

class _IdentityCard extends StatelessWidget {
  const _IdentityCard({
    required this.name,
    required this.color,
    required this.onRename,
  });

  final String name;
  final int color;
  final ValueChanged<String> onRename;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: CircleAvatar(backgroundColor: Color(color)),
        title: Text(name),
        subtitle: const Text('本地身份 · 无需注册'),
        trailing: IconButton(
          icon: const Icon(Icons.edit),
          tooltip: '修改昵称',
          onPressed: () async {
            final controller = TextEditingController(text: name);
            final newName = await showDialog<String>(
              context: context,
              builder: (dialogContext) => AlertDialog(
                title: const Text('修改昵称'),
                content: TextField(
                  controller: controller,
                  autofocus: true,
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(dialogContext).pop(),
                    child: const Text('取消'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.of(dialogContext)
                        .pop(controller.text.trim()),
                    child: const Text('确定'),
                  ),
                ],
              ),
            );
            if (newName != null && newName.isNotEmpty) onRename(newName);
          },
        ),
      ),
    );
  }
}
