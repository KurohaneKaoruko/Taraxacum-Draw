import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:taraxacum_draw/application/room/room_controller.dart';

/// 房主邀请二维码轮播页（多帧自动轮播，成员端连扫导入）。
class InviteQrView extends ConsumerStatefulWidget {
  const InviteQrView({super.key});

  @override
  ConsumerState<InviteQrView> createState() => _InviteQrViewState();
}

class _InviteQrViewState extends ConsumerState<InviteQrView> {
  Timer? _timer;
  int _frameIndex = 0;
  List<String> _frames = const [];
  String _code = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final invite = await ref.read(roomControllerProvider.notifier).createInviteCode();
    if (!mounted || invite == null) return;
    setState(() {
      _code = invite.code;
      _frames = invite.frames;
    });
    if (_frames.length > 1) {
      _timer = Timer.periodic(const Duration(milliseconds: 800), (_) {
        if (!mounted) return;
        setState(() => _frameIndex = (_frameIndex + 1) % _frames.length);
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final frameCount = _frames.length;
    return Scaffold(
      appBar: AppBar(title: const Text('邀请加入')),
      body: _frames.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    if (frameCount > 1)
                      Text(
                        '第 ${_frameIndex + 1} / $frameCount 帧 · 请依次扫描全部帧',
                        style: Theme.of(context).textTheme.titleMedium,
                      )
                    else
                      Text('请扫描二维码加入', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(12),
                      color: Colors.white,
                      child: QrImageView(data: _frames[_frameIndex]),
                    ),
                    const SizedBox(height: 16),
                    SelectableText(
                      _code,
                      maxLines: 4,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}
