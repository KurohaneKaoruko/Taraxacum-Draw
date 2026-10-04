import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:taraxacum_draw/application/room/room_controller.dart';
import 'package:taraxacum_draw/domain/room_state.dart';
import 'package:taraxacum_draw/infrastructure/transport/transport.dart';
import 'package:taraxacum_draw/presentation/canvas/canvas_view.dart';
import 'package:taraxacum_draw/presentation/canvas/layer_panel.dart';
import 'package:taraxacum_draw/presentation/home/home_page.dart';
import 'package:taraxacum_draw/presentation/room/invite_qr_view.dart';
import 'package:taraxacum_draw/presentation/room/invite_scan_view.dart';

/// 房间页：画布 + 成员管理 + 邀请 + 连接信息。
class RoomPage extends ConsumerWidget {
  const RoomPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ui = ref.watch(roomControllerProvider);
    final controller = ref.read(roomControllerProvider.notifier);
    final session = ui.session;

    ref.listen<RoomUiState>(roomControllerProvider, (previous, next) {
      if (next.stage == RoomStage.idle &&
          previous?.stage != RoomStage.idle) {
        Navigator.of(context, rootNavigator: true).pushReplacement(
          MaterialPageRoute<void>(builder: (_) => const HomePage()),
        );
      }
      if (next.error != null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(next.error!)));
      }
    });

    // 手动流程：等待导入邀请码。
    if (ui.stage == RoomStage.needsManual || session == null) {
      return _ManualJoinScaffold(controller: controller, ui: ui);
    }

    final isHost = session.isHost;
    final members = session.state.members.values.toList();

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmLeave(context, controller, isHost);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(session.roomName),
              Text(
                '房间号 ${session.roomId}'
                '${ui.activeMode == null ? "" : " · ${ui.activeMode!.label}"}'
                ' · ${members.length} 人',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
          actions: [
            if (isHost)
              IconButton(
                tooltip: '审批开关',
                isSelected: session.state.approvalRequired,
                icon: const Icon(Icons.how_to_reg),
                onPressed: () => controller
                    .setApprovalRequired(!session.state.approvalRequired),
              ),
            IconButton(
              tooltip: '邀请',
              icon: const Icon(Icons.qr_code),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const InviteQrView()),
              ),
            ),
            IconButton(
              tooltip: '成员',
              icon: Badge(
                isLabelVisible: session.pendingJoins.isNotEmpty && isHost,
                label: Text('${session.pendingJoins.length}'),
                child: const Icon(Icons.group),
              ),
              onPressed: () => _showMembers(context, controller, ui),
            ),
            IconButton(
              tooltip: '图层',
              icon: const Icon(Icons.layers),
              onPressed: () => showModalBottomSheet(
                context: context,
                builder: (_) => const LayerPanel(),
              ),
            ),
            ...CanvasWorkspace.appBarActions(context, ref),
            PopupMenuButton<String>(
              tooltip: '更多',
              onSelected: (value) {
                if (value == 'leave') {
                  _confirmLeave(context, controller, isHost);
                } else if (value == 'dissolve' && isHost) {
                  controller.dissolveRoom();
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'leave', child: Text('退出房间')),
                if (isHost)
                  const PopupMenuItem(
                    value: 'dissolve',
                    child: Text('解散房间'),
                  ),
              ],
            ),
          ],
        ),
        body: Column(
          children: [
            if (isHost && session.state.approvalRequired)
              const Material(
                color: Colors.amber,
                child: ListTile(
                  dense: true,
                  leading: Icon(Icons.how_to_reg),
                  title: Text('已开启加入审批，新成员需在成员列表中批准'),
                ),
              ),
            if (isHost)
              for (final pending in session.pendingJoins)
                Material(
                  child: ListTile(
                    dense: true,
                    leading: CircleAvatar(
                      backgroundColor: Color(pending.color),
                      child: Text(pending.name.characters.first),
                    ),
                    title: Text('${pending.name} 请求加入'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: '批准',
                          icon: const Icon(Icons.check),
                          onPressed: () => controller.approveMember(pending.peerId),
                        ),
                        IconButton(
                          tooltip: '拒绝',
                          icon: const Icon(Icons.close),
                          onPressed: () => controller.rejectMember(pending.peerId),
                        ),
                      ],
                    ),
                  ),
                ),
            _syncProgress(ref),
            const Expanded(child: CanvasWorkspace()),
          ],
        ),
      ),
    );
  }

  /// 中途加入补齐进度（task 5.3）。
  Widget _syncProgress(WidgetRef ref) {
    final progress = ref.read(roomControllerProvider.notifier).syncProgress;
    if (progress == null) return const SizedBox.shrink();
    return ValueListenableBuilder<double?>(
      valueListenable: progress,
      builder: (context, value, _) {
        if (value == null) return const SizedBox.shrink();
        return LinearProgressIndicator(
          value: value < 0 ? null : value,
          minHeight: 4,
        );
      },
    );
  }

  void _confirmLeave(
    BuildContext context,
    RoomController controller,
    bool isHost,
  ) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(isHost ? '退出房间' : '退出房间'),
        content: Text(isHost ? '退出后房主将转移给最早的成员。' : '确定退出当前房间？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          if (isHost)
            TextButton(
              onPressed: () {
                Navigator.of(dialogContext).pop();
                controller.dissolveRoom();
              },
              child: const Text('解散房间'),
            ),
          FilledButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              controller.leaveRoom();
            },
            child: const Text('退出'),
          ),
        ],
      ),
    );
  }

  void _showMembers(
    BuildContext context,
    RoomController controller,
    RoomUiState ui,
  ) {
    final session = ui.session;
    if (session == null) return;
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) {
        return Consumer(builder: (context, ref, _) {
          final current = ref.watch(roomControllerProvider).session;
          if (current == null) return const SizedBox.shrink();
          final members = current.state.members.values.toList();
          return SafeArea(
            child: ListView(
              shrinkWrap: true,
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text('成员（${members.length}）',
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                for (final member in members)
                  ListTile(
                    leading: CircleAvatar(backgroundColor: Color(member.color)),
                    title: Text(
                      member.name +
                          (member.peerId == current.selfPeerId ? '（我）' : ''),
                    ),
                    subtitle: Text(switch (member.role) {
                      RoomRole.host => '房主',
                      RoomRole.readOnly => '只读',
                      _ => '成员',
                    }),
                    trailing: current.isHost &&
                            member.peerId != current.selfPeerId
                        ? Switch(
                            value: member.role == RoomRole.readOnly,
                            onChanged: (readOnly) => controller.setMemberRole(
                              member.peerId,
                              readOnly ? RoomRole.readOnly : RoomRole.member,
                            ),
                          )
                        : null,
                  ),
              ],
            ),
          );
        });
      },
    );
  }
}

/// 手动加入兜底页：粘贴 / 扫描邀请码。
class _ManualJoinScaffold extends ConsumerWidget {
  const _ManualJoinScaffold({required this.controller, required this.ui});

  final RoomController controller;
  final RoomUiState ui;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('使用邀请码加入')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const Icon(Icons.qr_code_scanner, size: 64),
              const SizedBox(height: 16),
              Text(
                '自动连接失败（${ui.error ?? "网络不可达"}）。\n请使用房主的邀请二维码或邀请码文本加入。',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('扫描邀请二维码'),
                onPressed: () async {
                  final code = await Navigator.of(context).push<String>(
                    MaterialPageRoute(
                      builder: (_) => InviteScanView(
                        onComplete: (code) => controller.joinByInviteCode(code),
                      ),
                    ),
                  );
                  if (code != null && code.isNotEmpty) {
                    await controller.joinByInviteCode(code);
                  }
                },
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                icon: const Icon(Icons.paste),
                label: const Text('粘贴邀请码'),
                onPressed: () {
                  final textController = TextEditingController();
                  showDialog<void>(
                    context: context,
                    builder: (dialogContext) => AlertDialog(
                      title: const Text('粘贴邀请码'),
                      content: TextField(
                        controller: textController,
                        maxLines: 4,
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.of(dialogContext).pop(),
                          child: const Text('取消'),
                        ),
                        FilledButton(
                          onPressed: () {
                            Navigator.of(dialogContext).pop();
                            final text = textController.text.trim();
                            if (text.contains('TDI|') &&
                                text.split('\n').length > 1) {
                              controller.joinByInviteFrames(
                                text.split('\n').map((l) => l.trim()),
                              );
                            } else {
                              controller.joinByInviteCode(text);
                            }
                          },
                          child: const Text('加入'),
                        ),
                      ],
                    ),
                  );
                },
              ),
              const SizedBox(height: 24),
              TextButton(
                onPressed: () => controller.leaveRoom(),
                child: const Text('返回首页'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
