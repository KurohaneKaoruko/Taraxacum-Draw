import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:taraxacum_draw/application/presence/presence_controller.dart';
import 'package:taraxacum_draw/application/room/room_controller.dart';

/// 房间内文字聊天面板（底部弹层）。
class ChatPanel extends ConsumerStatefulWidget {
  const ChatPanel({super.key});

  @override
  ConsumerState<ChatPanel> createState() => _ChatPanelState();
}

class _ChatPanelState extends ConsumerState<ChatPanel> {
  final _input = TextEditingController();

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _send(WidgetRef ref) {
    final room = ref.read(roomControllerProvider);
    final identity = room.identity;
    if (identity == null) return;
    ref.read(presenceProvider.notifier).sendChat(
          selfPeerId: identity.peerId,
          selfName: identity.name,
          selfColor: identity.color,
          text: _input.text,
        );
    _input.clear();
  }

  @override
  Widget build(BuildContext context) {
    final presence = ref.watch(presenceProvider);
    final messages = presence.messages;

    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.6,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('房间聊天', style: Theme.of(context).textTheme.titleMedium),
            ),
            Expanded(
              child: messages.isEmpty
                  ? const Center(child: Text('还没有消息，发一条吧'))
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: messages.length,
                      itemBuilder: (context, index) {
                        final message = messages[index];
                        final time = DateTime.fromMillisecondsSinceEpoch(
                          message.timeMs,
                        );
                        final hh = time.hour.toString().padLeft(2, '0');
                        final mm = time.minute.toString().padLeft(2, '0');
                        return ListTile(
                          dense: true,
                          leading: CircleAvatar(
                            backgroundColor: Color(message.color),
                            child: Text(
                              message.name.characters.first,
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 13),
                            ),
                          ),
                          title: Text(
                            '${message.name}  $hh:$mm',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          subtitle: Text(message.text),
                        );
                      },
                    ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      decoration:
                          const InputDecoration(hintText: '输入消息…'),
                      onSubmitted: (_) => _send(ref),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.send),
                    onPressed: () => _send(ref),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
