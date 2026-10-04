# TaraxacumDraw 蒲公英

去中心化的联机绘画软件：设备之间直接对等连接、实时同步每个人的笔迹，
**无需自建服务器**，支持桌面（Windows / macOS / Linux）与移动（Android / iOS）。

```
flutter run -d windows   # 桌面端
flutter run -d <device>  # 移动端
```

## 功能

- **绘画工具**：画笔 / 橡皮 / 颜色 / 粗细、撤销重做、清空、图层（新建/删除/排序/显隐）、
  画布缩放平移、导出 PNG（2x）
- **多人实时协作**：房间创建/加入、笔迹实时同步、多人彩色光标、成员列表、房间聊天
- **权限**：加入审批开关、成员只读、房主转移、解散
- **断线韧性**：心跳保活、自动重连、重连后自动补齐缺失笔迹、超量快照

## 联机方式（无需服务器）

| 场景 | 方式 | 说明 |
|---|---|---|
| 同一 Wi-Fi | mDNS 自动发现 + TCP 直连 | 打开"加入房间"即列出可 join 的房间 |
| 跨网络 | WebRTC DataChannel | 信令经公共 MQTT over WS 中继（仅交换加密握手信息），绘画数据设备直连 |
| 无任何在线服务 | 邀请码 / 分帧二维码 | 房主二维码轮播，成员连扫导入后热点直连 |

加入时按 局域网 → 跨网 → 手动 顺序自动尝试并降级，当前方式在房间页可见。

## 项目结构（Flutter + Riverpod，四层架构）

```
lib/
├── presentation/    界面：home / room / canvas
├── application/     状态与编排：canvas_controller / room_controller /
│                    room_session(状态机) / sync_coordinator / presence
├── domain/          纯领域模型：Stroke/Layer/Op/Envelope/CanvasDocument/
│                    RoomState/LamportClock/OpCodec
└── infrastructure/  实现：transport(lan/webrtc/manual/signaling)/
                     render(图层缓存)/export(PNG)
```

- **同步模型**：一笔 = 一条不可变操作（op），各端按 `(lamport, authorId)`
  全序重放得到一致画布；撤销 = 追加 UndoOp；opId 幂等去重保证重传/补发安全
- **传输抽象**：上层只依赖 `Transport`/`PeerLink` 接口，三种连接方式可互换
- **渲染**：每图层离屏缓存 + 进行中笔画独立动态层（60fps，见 `docs/perf-baseline.md`）

## 开发

```bash
flutter analyze        # 静态检查（零告警基线）
flutter test           # 单元/组件测试（100+）
flutter build windows  # 构建桌面端
```

平台权限说明：iOS/macOS/Android 已声明本地网络发现、相册保存等权限
（见 `ios/Runner/Info.plist`、`macos/Runner/*.entitlements`、
`android/app/src/main/AndroidManifest.xml`）。

设计文档：`openspec/changes/build-p2p-drawing-app/`（proposal / specs / design / tasks）。
