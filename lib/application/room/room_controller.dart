import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import 'package:taraxacum_draw/application/canvas_controller.dart';
import 'package:taraxacum_draw/application/identity.dart';
import 'package:taraxacum_draw/application/room/room_network.dart';
import 'package:taraxacum_draw/application/room/room_session.dart';
import 'package:taraxacum_draw/application/sync/sync_coordinator.dart';
import 'package:taraxacum_draw/domain/canvas_document.dart';
import 'package:taraxacum_draw/domain/ids.dart';
import 'package:taraxacum_draw/domain/room_state.dart';
import 'package:taraxacum_draw/infrastructure/transport/lan_transport.dart';
import 'package:taraxacum_draw/infrastructure/transport/manual/invite_codec.dart';
import 'package:taraxacum_draw/infrastructure/transport/manual/manual_transport.dart';
import 'package:taraxacum_draw/infrastructure/transport/signaling/mqtt_signaling_client.dart';
import 'package:taraxacum_draw/infrastructure/transport/transport.dart';
import 'package:taraxacum_draw/infrastructure/transport/transport_selector.dart';
import 'package:taraxacum_draw/infrastructure/transport/webrtc/peer_connection_facade.dart';
import 'package:taraxacum_draw/infrastructure/transport/webrtc/webrtc_transport.dart';

/// 房间页界面状态。
class RoomUiState {
  const RoomUiState({
    this.identity,
    this.stage = RoomStage.idle,
    this.session,
    this.activeMode,
    this.needsManual = false,
    this.error,
  });

  final LocalIdentity? identity;
  final RoomStage stage;
  final RoomSession? session;

  /// 当前使用的连接方式（房主为 null：三种监听并存）。
  final ConnectionMode? activeMode;

  /// 自动加入失败，需走手动邀请码流程。
  final bool needsManual;
  final String? error;

  RoomUiState copyWith({
    LocalIdentity? identity,
    RoomStage? stage,
    RoomSession? session,
    ConnectionMode? activeMode,
    bool? needsManual,
    String? error,
    bool clearError = false,
  }) =>
      RoomUiState(
        identity: identity ?? this.identity,
        stage: stage ?? this.stage,
        session: session ?? this.session,
        activeMode: activeMode ?? this.activeMode,
        needsManual: needsManual ?? this.needsManual,
        error: clearError ? null : (error ?? this.error),
      );
}

enum RoomStage { idle, connecting, needsManual, inRoom }

final identityProvider =
    Provider<IdentityService>((ref) => IdentityService());

final roomControllerProvider =
    NotifierProvider<RoomController, RoomUiState>(RoomController.new);

/// 房间流程编排：创建 / 加入（自动选择）/ 手动邀请码 / 房内操作。
class RoomController extends Notifier<RoomUiState> {
  static const _uuid = Uuid();

  LanTransport? _lan;
  WebRtcTransport? _webrtc;
  ManualTransport? _manual;
  RoomNetworkAdapter? _adapter;
  SyncCoordinator? _sync;
  bool _limitWarned = false;


  @override
  RoomUiState build() {
    // 异步加载身份后刷新。
    Future<void>.microtask(() async {
      final identity = await ref.read(identityProvider).ensureIdentity();
      if (state.stage == RoomStage.idle) {
        state = state.copyWith(identity: identity);
      }
    });
    return const RoomUiState();
  }

  LocalIdentity get _identity => state.identity!;

  // ===== 创建房间（房主）=====

  Future<void> createRoom(String roomName) async {
    if (state.stage != RoomStage.idle) return;
    state = state.copyWith(stage: RoomStage.connecting, clearError: true);
    final roomId = _uuid.v4().substring(0, 8);
    try {
      final lan = LanTransport(selfPeer: _identity.peerId);
      final manual = ManualTransport(selfPeer: _identity.peerId);
      final webrtc = WebRtcTransport(
        selfPeer: _identity.peerId,
        signaling: MqttSignalingClient(),
        connectionFactory: RealPeerConnectionFacade.create,
      );
      await lan.start(asHost: true, roomId: roomId);
      await manual.start(asHost: true, roomId: roomId);
      try {
        await webrtc.start(asHost: true, roomId: roomId, roomKey: roomId);
      } catch (_) {
        // 公共信令不可用：房主侧退化为 LAN + 手动邀请。
      }

      _lan = lan;
      _manual = manual;
      _webrtc = webrtc;
      _wireSession(
        RoomSession(
          selfPeerId: _identity.peerId,
          selfName: _identity.name,
          selfColor: _identity.color,
          roomId: roomId,
          roomName: roomName,
          asHost: true,
        ),
        [lan, manual, webrtc],
      );
      state = state.copyWith(
        stage: RoomStage.inRoom,
        activeMode: null,
        session: _session,
      );
    } catch (error) {
      await _teardownTransports();
      state = state.copyWith(stage: RoomStage.idle, error: '$error');
    }
  }

  // ===== 加入房间 =====

  /// 按房间号自动加入：LAN 探测 → 跨网 → 手动兜底。
  Future<void> joinByRoomId(String roomId) async {
    await _joinAuto(roomId, roomKey: roomId);
  }

  Future<void> _joinAuto(RoomId roomId, {required String roomKey}) async {
    if (state.stage != RoomStage.idle) return;
    state = state.copyWith(stage: RoomStage.connecting, clearError: true);

    final lan = LanTransport(selfPeer: _identity.peerId);
    final webrtc = WebRtcTransport(
      selfPeer: _identity.peerId,
      signaling: MqttSignalingClient(),
      connectionFactory: RealPeerConnectionFacade.create,
    );
    final manual = ManualTransport(selfPeer: _identity.peerId);

    final selector = TransportSelector(
      autoAttempts: [
        AutoJoinAttempt(mode: ConnectionMode.lan, attempt: () async {
          await lan.start(asHost: false, roomId: roomId);
          final room = await lan.discoveredRooms
              .firstWhere((r) => r.roomId == roomId)
              .timeout(
                const Duration(seconds: 2),
                onTimeout: () => throw TimeoutException('局域网内未发现房间'),
              );
          return lan.dial(room.endpoint);
        }),
        AutoJoinAttempt(mode: ConnectionMode.webrtc, attempt: () async {
          return webrtc.dial(WebRtcEndpoint(roomId: roomId, roomKey: roomKey));
        }),
      ],
    );

    state = state.copyWith(stage: RoomStage.connecting);
    final selection = await selector.selectAndJoin();

    if (selection is AutoJoined) {
      _lan = lan;
      _webrtc = webrtc;
      _manual = manual;
      _wireSession(
        RoomSession(
          selfPeerId: _identity.peerId,
          selfName: _identity.name,
          selfColor: _identity.color,
          roomId: roomId,
          roomName: roomId,
          asHost: false,
        ),
        [lan, manual, webrtc],
      );
      _adapter!.sendHello(name: _identity.name, color: _identity.color);
      state = state.copyWith(
        stage: RoomStage.inRoom,
        activeMode: selection.mode,
        session: _session,
      );
      return;
    }

    if (selection is NeedsManual) {
      _manual = manual;
      state = state.copyWith(
        stage: RoomStage.needsManual,
        needsManual: true,
        error: '自动连接失败，请使用邀请码',
      );
      return;
    }

    await _teardownTransports();
    state = state.copyWith(stage: RoomStage.idle, error: '加入失败');
  }

  /// 粘贴 / 扫码导入邀请码加入。
  Future<void> joinByInviteCode(String inviteCode) async {
    try {
      final payload = InviteCodec.decodeInvite(inviteCode.trim());
      await joinByInvite(payload);
    } catch (error) {
      state = state.copyWith(error: '邀请码无效：$error');
    }
  }

  /// 扫码导入的多帧邀请加入。
  Future<void> joinByInviteFrames(Iterable<String> frames) async {
    try {
      final payload = InviteCodec.decodeInvite(
        InviteCodec.fromFrames(frames),
      );
      await joinByInvite(payload);
    } catch (error) {
      state = state.copyWith(error: '邀请码无效：$error');
    }
  }

  Future<void> joinByInvite(InvitePayload payload) async {
    if (state.stage != RoomStage.idle && state.stage != RoomStage.needsManual) {
      return;
    }
    state = state.copyWith(stage: RoomStage.connecting, clearError: true);
    final manual = _manual ?? ManualTransport(selfPeer: _identity.peerId);
    _manual = manual;
    try {
      await manual.start(asHost: false, roomId: payload.roomId);
      await manual
          .dial(LanEndpoint(host: payload.ips.first, port: payload.port))
          .timeout(const Duration(seconds: 8));

      _wireSession(
        RoomSession(
          selfPeerId: _identity.peerId,
          selfName: _identity.name,
          selfColor: _identity.color,
          roomId: payload.roomId,
          roomName: payload.hostName,
          asHost: false,
        ),
        [manual],
      );
      _adapter!.sendHello(name: _identity.name, color: _identity.color);
      state = state.copyWith(
        stage: RoomStage.inRoom,
        activeMode: ConnectionMode.manual,
        needsManual: false,
        session: _session,
      );
    } catch (error) {
      state = state.copyWith(stage: RoomStage.needsManual, error: '直连失败：$error');
    }
  }

  // ===== 房内操作 =====

  void setApprovalRequired(bool on) {
    _session?.setApprovalRequired(on);
    _adapter?.flush();
  }

  void approveMember(PeerId peer) {
    _session?.approve(peer);
    _adapter?.flush();
  }

  void rejectMember(PeerId peer) {
    _session?.reject(peer);
    _adapter?.flush();
  }

  void setMemberRole(PeerId peer, RoomRole role) {
    _session?.setRole(peer, role);
    _adapter?.flush();
  }
  Future<void> leaveRoom() async {
    _session?.leaveRoom();
    _adapter?.flush();
    await _teardownTransports();
    state = state.copyWith(
      stage: RoomStage.idle,
      session: null,
      activeMode: null,
      needsManual: false,
    );
  }

  Future<void> dissolveRoom() async {
    _session?.dissolve();
    _adapter?.flush();
    await _teardownTransports();
    state = state.copyWith(
      stage: RoomStage.idle,
      session: null,
      activeMode: null,
      needsManual: false,
    );
  }

  /// 房主邀请码（手动流程）。
  Future<InviteCode?> createInviteCode() async {
    final manual = _manual;
    if (manual == null || _session == null) return null;
    return manual.createInvite(
      roomId: _session!.roomId,
      roomName: _session!.roomName,
    );
  }

  /// 同步补齐进度（房间页进度条）。
  ValueNotifier<double?>? get syncProgress => _sync?.catchUpProgress;

  /// 首页昵称修改后刷新界面状态。
  void refreshIdentity(LocalIdentity identity) {
    state = state.copyWith(identity: identity);
  }

  // ===== 内部 =====

  RoomSession? _session;

  void _wireSession(RoomSession session, List<Transport> transports) {
    _session = session;
    _adapter = RoomNetworkAdapter(
      session: session,
      transports: transports,
      onChanged: () => state = state.copyWith(session: session),
      onPeerJoined: (peer) {
        if (session.isHost) _sync?.sendOpLogTo(peer);
      },
    );
    _adapter!.attach();
    _setupSync(session.roomId, transports);
  }

  void _setupSync(RoomId roomId, List<Transport> transports) {
    final canvas = ref.read(canvasProvider.notifier);
    canvas.authorId = _identity.peerId;
    // 进入新房间：以空白画布起步（历史由补齐流程填充，task 5.3）。
    canvas.adoptSnapshot(const CanvasState(layers: [], strokesByLayer: {}));
    _sync?.dispose();
    _sync = SyncCoordinator(
      selfPeerId: _identity.peerId,
      canvas: canvas,
      roomId: roomId,
    );
    _sync!.bind(transports);
    canvas.onLocalOp = (op) {
      _sync!.broadcastLocalOp(op);
      if (!_limitWarned && canvas.state.document.log.length >= _sync!.opLimit) {
        _limitWarned = true;
        state = state.copyWith(
          error: '操作数已达上限，建议导出画作后新建房间',
        );
      }
    };
    _limitWarned = false;
  }

  Future<void> _teardownTransports() async {
    await _adapter?.dispose();
    _adapter = null;
    _session = null;
    _sync?.dispose();
    _sync = null;
    _limitWarned = false;
    ref.read(canvasProvider.notifier).onLocalOp = null;
    await _lan?.stop();
    await _webrtc?.stop();
    await _manual?.stop();
    _lan = null;
    _webrtc = null;
    _manual = null;
  }
}
