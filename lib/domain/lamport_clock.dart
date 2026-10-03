/// Lamport 逻辑时钟（design.md D7）。
///
/// - 本地事件：`tick()` 自增 1
/// - 收到远端消息：`merge(remoteValue)` 取 max(local, remote) + 1
///
/// 保证因果序：若事件 A 因果先于 B，则 lamport(A) < lamport(B)。
class LamportClock {
  int _value = 0;

  int get value => _value;

  /// 本地产生一条新操作前的自增。
  int tick() => ++_value;

  /// 收到携带远端时钟值的消息时调用，返回合并后的本地值。
  int merge(int remoteValue) {
    _value = (_value > remoteValue ? _value : remoteValue) + 1;
    return _value;
  }
}
