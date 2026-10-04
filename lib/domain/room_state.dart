import 'package:taraxacum_draw/domain/ids.dart';

/// 成员角色。
enum RoomRole { host, member, readOnly }

/// 房间阶段（room-session 规格）。
enum RoomPhase { idle, lobby, active, closed }

/// 房间成员。
class RoomMember {
  const RoomMember({
    required this.peerId,
    required this.name,
    required this.color,
    required this.role,
    this.connected = true,
  });

  final PeerId peerId;
  final String name;
  final int color;
  final RoomRole role;
  final bool connected;

  RoomMember copyWith({String? name, RoomRole? role, bool? connected}) =>
      RoomMember(
        peerId: peerId,
        name: name ?? this.name,
        color: color,
        role: role ?? this.role,
        connected: connected ?? this.connected,
      );

  Map<String, Object?> toJson() => {
        'p': peerId,
        'n': name,
        'c': color,
        'r': role.index,
        'k': connected ? 1 : 0,
      };

  static RoomMember fromJson(Map<Object?, Object?> json) => RoomMember(
        peerId: json['p'] as String,
        name: (json['n'] as String?) ?? '',
        color: ((json['c'] as num?) ?? 0).toInt(),
        role: RoomRole.values[((json['r'] as num?) ?? 1).toInt()
            .clamp(0, RoomRole.values.length - 1)],
        connected: ((json['k'] as num?) ?? 1) != 0,
      );
}

/// 房间状态（不可变快照；房主权威广播，成员端整体应用）。
class RoomState {
  const RoomState({
    required this.roomId,
    required this.roomName,
    required this.phase,
    required this.members,
    required this.joinOrder,
    required this.approvalRequired,
    required this.capacity,
    required this.version,
  });

  static const int defaultCapacity = 16;

  final RoomId roomId;
  final String roomName;
  final RoomPhase phase;

  /// 全体成员（含本端）。
  final Map<PeerId, RoomMember> members;

  /// 加入顺序（房主转移按此序）。
  final List<PeerId> joinOrder;
  final bool approvalRequired;
  final int capacity;

  /// 快照版本号（房主每次变更自增；成员端只接受更大版本）。
  final int version;

  bool get isFull => members.length >= capacity;

  bool contains(PeerId peer) => members.containsKey(peer);

  RoomRole? roleOf(PeerId peer) => members[peer]?.role;

  /// 当前房主（成员侧随快照更新；房主侧即本端）。
  PeerId? get hostPeerId {
    for (final member in members.values) {
      if (member.role == RoomRole.host) return member.peerId;
    }
    return null;
  }

  /// 是否允许该成员绘画（只读控制）。
  bool canDraw(PeerId peer) => members[peer]?.role != RoomRole.readOnly;

  /// 在座且在线的成员（按加入顺序）。
  List<RoomMember> connectedByJoinOrder() => [
        for (final peer in joinOrder)
          if (members[peer] != null && members[peer]!.connected)
            members[peer]!,
      ];

  Map<String, Object?> toJson() => {
        'room': roomId,
        'name': roomName,
        'phase': phase.index,
        'approval': approvalRequired,
        'cap': capacity,
        'v': version,
        'members': [for (final m in members.values) m.toJson()],
        'order': joinOrder,
      };

  static RoomState fromJson(Map<Object?, Object?> json) {
    final memberList = (json['members'] as List? ?? [])
        .map((m) => RoomMember.fromJson(Map<Object?, Object?>.from(m as Map)))
        .toList();
    return RoomState(
      roomId: json['room'] as String,
      roomName: (json['name'] as String?) ?? '',
      phase: RoomPhase.values[((json['phase'] as num?) ?? 2)
          .toInt()
          .clamp(0, RoomPhase.values.length - 1)],
      members: {for (final m in memberList) m.peerId: m},
      joinOrder: (json['order'] as List? ?? []).cast<String>(),
      approvalRequired: (json['approval'] as bool?) ?? false,
      capacity: ((json['cap'] as num?) ?? RoomState.defaultCapacity).toInt(),
      version: ((json['v'] as num?) ?? 0).toInt(),
    );
  }
}
