/// 领域层通用标识类型。
///
/// 全部以字符串承载：peerId 为设备本地生成的 UUID，
/// 其余 id 在生成处保证唯一（uuid 或 房间内自增/短随机串）。
library;

typedef PeerId = String;
typedef RoomId = String;
typedef LayerId = String;
typedef StrokeId = String;
typedef OpId = String;
