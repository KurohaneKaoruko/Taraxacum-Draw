import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'package:taraxacum_draw/infrastructure/transport/manual/invite_codec.dart';

/// 扫描邀请二维码：自动收集多帧，集齐后回调完整邀请码。
class InviteScanView extends StatefulWidget {
  const InviteScanView({super.key, required this.onComplete});

  /// 集齐所有帧后回调（完整邀请码文本）。
  final ValueChanged<String> onComplete;

  @override
  State<InviteScanView> createState() => _InviteScanViewState();
}

class _InviteScanViewState extends State<InviteScanView> {
  final Map<int, String> _parts = {};
  int? _total;

  void _onDetect(BarcodeCapture capture) {
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value == null) continue;
      try {
        final part = InviteCodec.parseFrame(value);
        if (part == null) {
          // 单帧完整邀请码。
          widget.onComplete(value);
          if (mounted) Navigator.of(context).pop(value);
          return;
        }
        setState(() {
          _parts[part.$1] = part.$3;
          _total = part.$2;
        });
        if (_total != null && _parts.length == _total) {
          final code =
              [for (var i = 1; i <= _total!; i++) _parts[i]!].join();
          widget.onComplete(code);
          if (mounted) Navigator.of(context).pop(code);
          return;
        }
      } on FormatException {
        // 噪声二维码，忽略。
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final collected = _total == null ? 0 : _parts.length;
    return Scaffold(
      appBar: AppBar(title: const Text('扫描邀请二维码')),
      body: Column(
        children: [
          Expanded(child: MobileScanner(onDetect: _onDetect)),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              _total == null
                  ? '请扫描房主的邀请二维码'
                  : '已收集 $collected / $_total 帧',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
        ],
      ),
    );
  }
}
