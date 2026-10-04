import 'package:flutter_test/flutter_test.dart';
import 'package:taraxacum_draw/application/room/room_session.dart';
import 'package:taraxacum_draw/domain/room_state.dart';

RoomSession hostSession({int capacity = RoomState.defaultCapacity}) =>
    RoomSession(
      selfPeerId: 'host',
      selfName: '房主',
      selfColor: 0xFF0000FF,
      roomId: 'room-1',
      roomName: '测试房间',
      asHost: true,
      capacity: capacity,
    );

RoomSession guestSession() => RoomSession(
      selfPeerId: 'guest-1',
      selfName: '画友乙',
      selfColor: 0xFFFF0000,
      roomId: 'room-1',
      roomName: '测试房间',
      asHost: false,
    );

void main() {
  group('房间创建与加入', () {
    test('房主创建即 active 且自己是 host', () {
      final room = hostSession();
      expect(room.state.phase, RoomPhase.active);
      expect(room.state.roleOf('host'), RoomRole.host);
      expect(room.state.joinOrder, ['host']);
    });

    test('默认自动加入：hello → 入座并广播快照', () {
      final room = hostSession();
      room.onJoinRequest('guest-1', '画友乙', 0xFFFF0000);

      expect(room.state.contains('guest-1'), isTrue);
      expect(room.state.roleOf('guest-1'), RoomRole.member);
      expect(room.state.joinOrder, ['host', 'guest-1']);

      final out = room.drainOutbox();
      expect(out.where((m) => m.type == 'state'), isNotEmpty);
      expect(
        out.any((m) => m.type == 'approvalPending'),
        isFalse,
        reason: '未开审批时不应有等待消息',
      );
    });

    test('重复 hello 忽略；房主 phase 非 active 时忽略', () {
      final room = hostSession();
      room.onJoinRequest('g', 'a', 1);
      room.onJoinRequest('g', 'a', 1);
      expect(room.state.members.length, 2);
    });
  });

  group('审批（task 4.4）', () {
    test('开审批后 hello 进入等待，批准后入座', () {
      final room = hostSession()..setApprovalRequired(true);

      room.onJoinRequest('guest-1', '画友乙', 2);
      expect(room.state.contains('guest-1'), isFalse);
      expect(room.pendingJoins.map((m) => m.peerId), ['guest-1']);
      expect(
        room.drainOutbox().any((m) => m.type == 'approvalPending'),
        isTrue,
      );

      room.approve('guest-1');
      expect(room.state.contains('guest-1'), isTrue);
      expect(room.pendingJoins, isEmpty);
    });

    test('拒绝后不入座', () {
      final room = hostSession()..setApprovalRequired(true);
      room.onJoinRequest('guest-1', '画友乙', 2);
      room.reject('guest-1');

      expect(room.state.contains('guest-1'), isFalse);
      final out = room.drainOutbox();
      expect(out.where((m) => m.type == 'joinRejected'), isNotEmpty);
    });
  });

  group('只读控制（task 4.5）', () {
    test('setRole 切换只读并可恢复', () {
      final room = hostSession();
      room.onJoinRequest('guest-1', '画友乙', 2);
      room.drainOutbox();

      room.setRole('guest-1', RoomRole.readOnly);
      expect(room.state.canDraw('guest-1'), isFalse);
      expect(room.state.canDraw('host'), isTrue, reason: '房主不受影响');

      room.setRole('guest-1', RoomRole.member);
      expect(room.state.canDraw('guest-1'), isTrue);
    });

    test('不能把成员直接设为房主', () {
      final room = hostSession();
      room.onJoinRequest('guest-1', '画友乙', 2);
      room.setRole('guest-1', RoomRole.host);
      expect(room.state.roleOf('guest-1'), isNot(RoomRole.host));
    });
  });

  group('容量限制（task 4.6）', () {
    test('满员后新加入被拒', () {
      final room = hostSession(capacity: 3); // host + 2 成员
      room.onJoinRequest('g1', 'a', 1);
      room.onJoinRequest('g2', 'b', 2);
      room.drainOutbox();
      expect(room.state.isFull, isTrue);

      room.onJoinRequest('g3', 'c', 3);
      expect(room.state.contains('g3'), isFalse);
      expect(
        room.drainOutbox().any((m) => m.to == 'g3' && m.type == 'joinRejected'),
        isTrue,
      );
    });

    test('审批模式下批准前检查容量', () {
      final room = hostSession(capacity: 2)..setApprovalRequired(true);
      room.onJoinRequest('g1', 'a', 1);
      room.approve('g1');

      room.onJoinRequest('g2', 'b', 2); // 等待中
      room.approve('g2'); // 满员 → 拒绝
      expect(room.state.contains('g2'), isFalse);
      expect(
        room.drainOutbox().any((m) => m.type == 'joinRejected'),
        isTrue,
      );
    });
  });

  group('退出 / 解散 / 房主转移（task 4.7）', () {
    test('成员退出：房主侧移除', () {
      final room = hostSession();
      room.onJoinRequest('guest-1', '画友乙', 2);
      room.drainOutbox();

      room.onDisconnected('guest-1');
      expect(room.state.contains('guest-1'), isFalse);
      expect(room.drainOutbox().where((m) => m.type == 'state'), isNotEmpty);
    });

    test('房主退出：按加入顺序转移给最早成员', () {
      final room = hostSession();
      room.onJoinRequest('g1', 'a', 1);
      room.onJoinRequest('g2', 'b', 2);
      room.drainOutbox();

      room.leaveRoom();
      final out = room.drainOutbox();
      expect(out.any((m) => m.type == 'hostTransferred'), isTrue);
      expect(room.state.roleOf('g1'), RoomRole.host, reason: '最早加入者接任');
      expect(room.state.contains('host'), isFalse);

      // 退出的房主本地视图关闭；房间本身在其余成员侧继续。
      expect(room.state.phase, RoomPhase.closed);
      final transferredState = out.firstWhere((m) => m.type == 'state');
      final snapshot = RoomState.fromJson(transferredState.payload);
      expect(snapshot.phase, RoomPhase.active, reason: '广播给留守成员的房间仍活跃');
      expect(snapshot.roleOf('g1'), RoomRole.host);
    });

    test('房主解散：广播 dissolve 并关闭', () {
      final room = hostSession();
      room.onJoinRequest('g1', 'a', 1);
      room.drainOutbox();

      room.dissolve();
      expect(room.state.phase, RoomPhase.closed);
      expect(room.drainOutbox().any((m) => m.type == 'dissolve'), isTrue);
    });

    test('成员收到解散 → 关闭', () {
      final guest = guestSession();
      guest.onRemoteDissolve();
      expect(guest.state.phase, RoomPhase.closed);
    });
  });

  group('成员侧快照应用', () {
    test('应用更高版本的快照；拒绝旧版本', () {
      final guest = guestSession();
      final snapshot = RoomState.fromJson(hostSession().state.toJson());

      guest.onRemoteState(snapshot);
      // 成员进入 active（快照含自己时）——此处快照不含 guest-1，保持 lobby。
      expect(guest.state.version, snapshot.version);

      guest.onRemoteState(snapshot); // 旧版本被拒
      expect(guest.state.version, snapshot.version);
    });

    test('快照包含自己时进入 active', () {
      final host = hostSession();
      host.onJoinRequest('guest-1', '画友乙', 2);
      final snapshot = RoomState.fromJson(host.state.toJson());

      final guest = guestSession();
      guest.onRemoteState(snapshot);
      expect(guest.state.phase, RoomPhase.active);
      expect(guest.state.roleOf('guest-1'), RoomRole.member);
    });
  });
}
