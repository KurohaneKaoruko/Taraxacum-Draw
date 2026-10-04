import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:taraxacum_draw/application/canvas_controller.dart';
import 'package:taraxacum_draw/domain/canvas_document.dart';
import 'package:taraxacum_draw/domain/envelope.dart';
import 'package:taraxacum_draw/domain/ids.dart';
import 'package:taraxacum_draw/domain/op.dart';
import 'package:taraxacum_draw/domain/op_codec.dart';
import 'package:taraxacum_draw/infrastructure/transport/transport.dart';

/// 实时同步协调器（task 5.1–5.6）。
///
/// - 本地 op（画布回调）→ op 信封广播，携带发送方 seq（5.1）；
/// - 入站 op 信封：seq 缺口检测 → 请求重传（5.1）；op 幂等去重；
/// - 成员加入：房主补发 op-log / 快照（5.3/5.6）；
/// - 撤销即 UndoOp，与笔画走同一管道（5.5）。
class SyncCoordinator {
  SyncCoordinator({
    required this.selfPeerId,
    required this.canvas,
    required this.roomId,
    this.catchUpChunkOps = 200,
    this.snapshotThreshold = 2000,
    this.opLimit = 20000,
  });

  final PeerId selfPeerId;
  final CanvasController canvas;
  final RoomId roomId;

  /// 补齐分片大小（每条 sync 信封携带的 op 数）。
  final int catchUpChunkOps;

  /// op-log 超过该条数时，中途加入改发快照（5.6）。
  final int snapshotThreshold;

  /// op-log 硬上限，达到后 UI 提示导出新建（5.6）。
  final int opLimit;

  final List<Transport> _transports = [];
  final List<StreamSubscription> _subs = [];
  int _seq = 0;
  final Map<PeerId, int> _lastSeq = {};
  final Map<PeerId, DateTime> _lastNeedSent = {};
  final List<Envelope> _sentWindow = [];

  /// 中途加入补齐进度（null = 无进行中任务）。
  final ValueNotifier<double?> catchUpProgress = ValueNotifier(null);

  /// op 数是否已达硬上限。
  bool get opLimitExceeded => canvas.document.log.length >= opLimit;

  void bind(List<Transport> transports) {
    for (final transport in transports) {
      if (_transports.contains(transport)) continue;
      _transports.add(transport);
      _subs.add(transport.messages.listen(handleEnvelope));
    }
  }

  void dispose() {
    for (final sub in _subs) {
      sub.cancel();
    }
    _subs.clear();
    _transports.clear();
  }

  // ===== 本地 op 出口 =====

  /// 广播本地产生的 op（由画布回调调用）。
  void broadcastLocalOp(Op op) {
    _send(Envelope(
      type: MessageType.op,
      roomId: roomId,
      from: selfPeerId,
      seq: ++_seq,
      lamport: op.lamport,
      payload: OpCodec.encode(op),
    ));
  }

  void _send(Envelope envelope) {
    if (envelope.type == MessageType.op) {
      _sentWindow.add(envelope);
      if (_sentWindow.length > 512) _sentWindow.removeAt(0);
    }
    for (final transport in _transports) {
      transport.broadcast(envelope);
    }
  }

  // ===== 入站分发（测试可直接注入）=====

  void handleEnvelope(Envelope envelope) {
    if (envelope.from == selfPeerId) return;
    switch (envelope.type) {
      case MessageType.op:
        _onOpEnvelope(envelope);
      case MessageType.sync:
        _onSyncEnvelope(envelope);
      default:
        break;
    }
  }

  void _onOpEnvelope(Envelope envelope) {
    final last = _lastSeq[envelope.from];
    if (last != null && envelope.seq > last + 1) {
      _requestRetransmit(envelope.from, last + 1, envelope.seq - 1);
    }
    if (last == null || envelope.seq > last) {
      _lastSeq[envelope.from] = envelope.seq;
    }
    canvas.applyRemoteOp(OpCodec.decode(envelope.payload));
  }

  void _requestRetransmit(PeerId to, int fromSeq, int toSeq) {
    // 简单节流：同一对端 500ms 内只发一次缺口请求。
    final now = DateTime.now();
    final lastSent = _lastNeedSent[to];
    if (lastSent != null &&
        now.difference(lastSent) < const Duration(milliseconds: 500)) {
      return;
    }
    _lastNeedSent[to] = now;
    _publishSync({'rt': 'need', 'from': fromSeq, 'to': toSeq}, to: to);
  }

  void _onSyncEnvelope(Envelope envelope) {
    if (envelope.to != null && envelope.to != selfPeerId) return;
    final json =
        jsonDecode(utf8.decode(envelope.payload)) as Map<String, Object?>;
    switch (json['rt']) {
      case 'need':
        if (!_resend(envelope.from, (json['from'] as num).toInt(),
            (json['to'] as num).toInt())) {
          // 窗口内没有：对方缺口过老，提示其走重新加入（5.4 上层文案）。
          catchUpProgress.value = -1;
        }
      case 'ops':
        _applyOpsChunk(json);
      case 'snap':
        final state = CanvasState.fromJson(
            Map<Object?, Object?>.from(json['state'] as Map));
        canvas.adoptSnapshot(state);
        catchUpProgress.value = null;
      default:
        break;
    }
  }

  bool _resend(PeerId to, int fromSeq, int toSeq) {
    final missing = _sentWindow
        .where((e) => e.seq >= fromSeq && e.seq <= toSeq)
        .toList();
    if (missing.isEmpty) return false;
    for (final envelope in missing) {
      for (final transport in _transports) {
        transport.sendTo(envelope, to);
      }
    }
    return true;
  }

  void _applyOpsChunk(Map<String, Object?> json) {
    final ops = (json['ops'] as List? ?? []).cast<String>();
    for (final encoded in ops) {
      canvas.applyRemoteOp(OpCodec.decode(base64Decode(encoded)));
    }
    final index = (json['i'] as num).toInt();
    final total = (json['total'] as num).toInt();
    catchUpProgress.value = total <= 0 ? null : (index + 1) / total;
    if (index + 1 >= total) catchUpProgress.value = null;
  }

  // ===== 中途加入补齐（房主侧，task 5.3/5.6）=====

  /// 向新成员补发：op 数少发全量日志分片，多则发快照。
  Future<void> sendOpLogTo(PeerId peer) async {
    final log = canvas.document.log;
    if (log.isEmpty) return;

    if (log.length > snapshotThreshold) {
      await _publishSync({
        'rt': 'snap',
        'state': canvas.document.state.toJson(),
      }, to: peer);
      return;
    }

    final encoded = [
      for (final op in log) base64Encode(OpCodec.encode(op)),
    ];
    final total = (encoded.length / catchUpChunkOps).ceil();
    for (var i = 0; i < total; i++) {
      final chunk = encoded
          .skip(i * catchUpChunkOps)
          .take(catchUpChunkOps)
          .toList();
      await _publishSync(
        {'rt': 'ops', 'i': i, 'total': total, 'ops': chunk},
        to: peer,
      );
    }
  }

  Future<void> _publishSync(Map<String, Object?> payload,
      {PeerId? to}) async {
    final envelope = Envelope(
      type: MessageType.sync,
      roomId: roomId,
      from: selfPeerId,
      to: to,
      seq: 0,
      lamport: 0,
      payload: Uint8List.fromList(utf8.encode(jsonEncode(payload))),
    );
    for (final transport in _transports) {
      if (to != null) {
        transport.sendTo(envelope, to);
      } else {
        transport.broadcast(envelope);
      }
    }
  }
}
