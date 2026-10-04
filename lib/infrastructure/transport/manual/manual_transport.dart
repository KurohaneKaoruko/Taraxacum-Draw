import 'dart:io';

import 'package:taraxacum_draw/domain/ids.dart';
import 'package:taraxacum_draw/infrastructure/transport/lan_transport.dart';
import 'package:taraxacum_draw/infrastructure/transport/manual/invite_codec.dart';
import 'package:taraxacum_draw/infrastructure/transport/transport.dart';

/// 手动信令传输（task 3.4）：TCP 直连 + 邀请码握手。
///
/// 与 LAN 传输共用同一套 TCP 链路与信封帧，但不依赖 mDNS，
/// 也不依赖任何在线服务：邀请码携带房主地址，成员扫码/粘贴导入后直连。
/// 适用于同一热点下 mDNS 被屏蔽、或跨网且公共信令不可达的场景。
class ManualTransport extends LanTransport {
  ManualTransport({required super.selfPeer})
      : super(enableMdns: false, serviceNamePrefix: 'TDM');

  @override
  ConnectionMode get mode => ConnectionMode.manual;

  /// 房主生成邀请（须先以 asHost 启动）。
  ///
  /// [ips] 不传时自动枚举本机所有局域网 IPv4（测试可显式传入）。
  Future<InviteCode> createInvite({
    required RoomId roomId,
    required String roomName,
    List<String>? ips,
  }) async {
    final port = boundPort;
    if (!isRunning || port == 0) {
      throw StateError('请先以房主身份启动手动传输');
    }
    final candidates = ips ??
        (await NetworkInterface.list(type: InternetAddressType.IPv4))
            .expand((i) => i.addresses)
            .map((a) => a.address)
            .toList();
    final payload = InvitePayload(
      version: 1,
      roomId: roomId,
      hostPeerId: selfPeer,
      hostName: roomName,
      port: port,
      ips: candidates,
    );
    final code = InviteCodec.encodeInvite(payload);
    return InviteCode(
      payload: payload,
      code: code,
      frames: InviteCodec.toFrames(code),
    );
  }

  /// 成员导入邀请帧集合（乱序/多次扫描皆可）并解析。
  InvitePayload importInvite(Iterable<String> frames) {
    final code = InviteCodec.fromFrames(frames);
    return InviteCodec.decodeInvite(code);
  }

  /// 成员生成应答码（连接成功后回传房主确认身份）。
  String createAnswerCode({required String guestName}) =>
      InviteCodec.encodeAnswer(AnswerInfo(guestPeerId: selfPeer, guestName: guestName));

  /// 房主解析应答码。
  AnswerInfo importAnswerCode(String code) => InviteCodec.decodeAnswer(code);
}

/// 一次邀请的完整产物：载荷、单行码、分帧（二维码轮播用）。
class InviteCode {
  const InviteCode({
    required this.payload,
    required this.code,
    required this.frames,
  });

  final InvitePayload payload;
  final String code;

  /// 二维码帧（与 [InviteCodec.toFrames] 一致，轮播展示）。
  final List<String> frames;
}
