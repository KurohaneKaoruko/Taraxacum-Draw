import 'package:taraxacum_draw/domain/ids.dart';
import 'package:taraxacum_draw/domain/room_state.dart';
import 'package:taraxacum_draw/application/room/room_message.dart';

/// 房间会话控制器（design.md D6：房主权威）。
///
/// 纯状态机，不触碰网络：
/// - 本端意图 / 远端消息进入 → 状态迁移 + 产生待广播消息（[drainOutbox]）；
/// - 房主侧任何变更广播**全量状态快照**（带版本号），成员端整体应用；
/// - 审批、只读、容量、房主转移均为状态迁移规则。
class RoomSession {
  RoomSession({
    required this.selfPeerId,
    required this.selfName,
    required this.selfColor,
    required this.roomId,
    required this.roomName,
    required bool asHost,
    int capacity = RoomState.defaultCapacity,
  })  : isHost = asHost {
    _state = RoomState(
      roomId: roomId,
      roomName: roomName,
      phase: asHost ? RoomPhase.active : RoomPhase.lobby,
      members: asHost
          ? {
              selfPeerId: RoomMember(
                peerId: selfPeerId,
                name: selfName,
                color: selfColor,
                role: RoomRole.host,
              ),
            }
          : const {},
      joinOrder: asHost ? [selfPeerId] : [],
      approvalRequired: false,
      capacity: capacity,
      version: 0,
    );
  }

  final PeerId selfPeerId;
  final String selfName;
  final int selfColor;
  final RoomId roomId;
  final String roomName;
  final bool isHost;

  /// 当前房主（本端为房主时即 selfPeerId）。
  PeerId? get hostPeerId => state.hostPeerId;

  RoomState _state = _emptyState;
  static const RoomState _emptyState = RoomState(
    roomId: '',
    roomName: '',
    phase: RoomPhase.idle,
    members: {},
    joinOrder: [],
    approvalRequired: false,
    capacity: RoomState.defaultCapacity,
    version: 0,
  );

  RoomState get state => _state;

  /// 等待审批的加入请求（房主侧）。
  final List<RoomMember> pendingJoins = [];

  final List<RoomMessage> _outbox = [];

  /// 取走所有待广播消息（网络层负责经传输发送）。
  List<RoomMessage> drainOutbox() {
    final out = List.of(_outbox);
    _outbox.clear();
    return out;
  }

  // ===== 房主侧：状态变更 =====

  void _mutate(RoomState Function(RoomState) transform) {
    assert(isHost, '只有房主能变更房间状态');
    _state = transform(_state);
    _outbox.add(RoomMessage.broadcast('state', _state.toJson()));
  }

  /// 房主开关"新成员需审批"。
  void setApprovalRequired(bool on) => _mutate((s) => RoomState(
        roomId: s.roomId,
        roomName: s.roomName,
        phase: s.phase,
        members: s.members,
        joinOrder: s.joinOrder,
        approvalRequired: on,
        capacity: s.capacity,
        version: s.version + 1,
      ));

  /// 处理加入请求（hello）。
  void onJoinRequest(PeerId peer, String name, int color) {
    if (!isHost || _state.phase != RoomPhase.active) return;
    if (_state.contains(peer)) return;

    if (_state.isFull) {
      _outbox.add(RoomMessage.to(peer, 'joinRejected', {'reason': 'full'}));
      return;
    }
    final member = RoomMember(peerId: peer, name: name, color: color, role: RoomRole.member);
    if (_state.approvalRequired) {
      if (!pendingJoins.any((m) => m.peerId == peer)) {
        pendingJoins.add(member);
      }
      _outbox.add(RoomMessage.to(peer, 'approvalPending', {}));
      return;
    }
    _admit(member);
  }

  /// 批准等待中的成员。
  void approve(PeerId peer) {
    final index = pendingJoins.indexWhere((m) => m.peerId == peer);
    if (index < 0) return;
    final member = pendingJoins.removeAt(index);
    if (_state.isFull) {
      _outbox.add(RoomMessage.to(peer, 'joinRejected', {'reason': 'full'}));
      return;
    }
    _admit(member);
  }

  /// 拒绝等待中的成员。
  void reject(PeerId peer) {
    pendingJoins.removeWhere((m) => m.peerId == peer);
    _outbox.add(RoomMessage.to(peer, 'joinRejected', {'reason': 'rejected'}));
  }

  void _admit(RoomMember member) {
    _mutate((s) => RoomState(
          roomId: s.roomId,
          roomName: s.roomName,
          phase: s.phase,
          members: {...s.members, member.peerId: member},
          joinOrder: [...s.joinOrder, member.peerId],
          approvalRequired: s.approvalRequired,
          capacity: s.capacity,
          version: s.version + 1,
        ));
  }

  /// 设置成员角色（只读控制）。
  void setRole(PeerId peer, RoomRole role) {
    if (!isHost || !_state.contains(peer) || role == RoomRole.host) return;
    _mutate((s) => RoomState(
          roomId: s.roomId,
          roomName: s.roomName,
          phase: s.phase,
          members: {...s.members, peer: s.members[peer]!.copyWith(role: role)},
          joinOrder: s.joinOrder,
          approvalRequired: s.approvalRequired,
          capacity: s.capacity,
          version: s.version + 1,
        ));
  }

  /// 成员掉线（房主侧）：移出房间并广播。
  void onDisconnected(PeerId peer) {
    if (!isHost || peer == selfPeerId || !_state.contains(peer)) return;
    _mutate((s) => RoomState(
          roomId: s.roomId,
          roomName: s.roomName,
          phase: s.phase,
          members: Map.of(s.members)..remove(peer),
          joinOrder: s.joinOrder.where((p) => p != peer).toList(),
          approvalRequired: s.approvalRequired,
          capacity: s.capacity,
          version: s.version + 1,
        ));
  }

  /// 本端退出：房主则先转移房主身份；随后房间对本端关闭。
  void leaveRoom() {
    if (isHost) {
      final successors = _state
          .connectedByJoinOrder()
          .where((m) => m.peerId != selfPeerId)
          .toList();
      if (successors.isNotEmpty) {
        final next = successors.first;
        _mutate((s) => RoomState(
              roomId: s.roomId,
              roomName: s.roomName,
              phase: RoomPhase.active,
              members: {
                ...Map.of(s.members)..remove(selfPeerId),
                next.peerId: next.copyWith(role: RoomRole.host),
              },
              joinOrder: s.joinOrder.where((p) => p != selfPeerId).toList(),
              approvalRequired: s.approvalRequired,
              capacity: s.capacity,
              version: s.version + 1,
            ));
        _outbox.add(RoomMessage.broadcast(
          'hostTransferred',
          {'peer': next.peerId},
        ));
      }
    } else {
      _outbox.add(RoomMessage.broadcast('bye', {}));
    }
    _state = RoomState(
      roomId: _state.roomId,
      roomName: _state.roomName,
      phase: RoomPhase.closed,
      members: _state.members,
      joinOrder: _state.joinOrder,
      approvalRequired: _state.approvalRequired,
      capacity: _state.capacity,
      version: _state.version + 1,
    );
  }

  /// 房主解散房间。
  void dissolve() {
    assert(isHost);
    _outbox.add(RoomMessage.broadcast('dissolve', {}));
    _state = RoomState(
      roomId: _state.roomId,
      roomName: _state.roomName,
      phase: RoomPhase.closed,
      members: _state.members,
      joinOrder: _state.joinOrder,
      approvalRequired: _state.approvalRequired,
      capacity: _state.capacity,
      version: _state.version + 1,
    );
  }

  // ===== 成员侧：应用权威快照 =====

  /// 成员收到房主的全量状态快照。
  void onRemoteState(RoomState snapshot) {
    if (isHost) return;
    if (snapshot.version <= _state.version) return; // 只接受更新版本
    _state = snapshot;
    if (snapshot.contains(selfPeerId)) {
      // 已在座 → active。
      if (_state.phase == RoomPhase.lobby) {
        _state = RoomState(
          roomId: _state.roomId,
          roomName: _state.roomName,
          phase: RoomPhase.active,
          members: _state.members,
          joinOrder: _state.joinOrder,
          approvalRequired: _state.approvalRequired,
          capacity: _state.capacity,
          version: _state.version,
        );
      }
    }
  }

  /// 成员被拒绝（或房间已满）。
  void onJoinRejected() {
    _state = RoomState(
      roomId: _state.roomId,
      roomName: _state.roomName,
      phase: RoomPhase.closed,
      members: _state.members,
      joinOrder: _state.joinOrder,
      approvalRequired: _state.approvalRequired,
      capacity: _state.capacity,
      version: _state.version + 1,
    );
  }

  /// 成员收到解散。
  void onRemoteDissolve() {
    if (isHost) return;
    _state = RoomState(
      roomId: _state.roomId,
      roomName: _state.roomName,
      phase: RoomPhase.closed,
      members: _state.members,
      joinOrder: _state.joinOrder,
      approvalRequired: _state.approvalRequired,
      capacity: _state.capacity,
      version: _state.version + 1,
    );
  }
}
