# 架构说明

> 对应规格：`openspec/changes/build-p2p-drawing-app/specs/`；
> 设计决策全文：同目录 `design.md`。本文面向开发者，描述代码实际结构与关键机制。

## 1. 分层

```
presentation   页面与组件（Riverpod Consumer）
application    状态控制器：CanvasController / RoomController /
               RoomSession(纯状态机) / SyncCoordinator / PresenceController
domain         纯 Dart：Stroke / Layer / Op / Envelope / CanvasDocument /
               RoomState / LamportClock / OpCodec —— 零 IO 依赖，全部可单测
infrastructure 传输(lan/webrtc/manual/signaling) / 渲染缓存 / PNG 导出
```

依赖方向：presentation → application → domain；infrastructure 实现
application/domain 定义的接口（`Transport`、`PeerLink`、`PeerConnectionFacade`、
`IdentityStorage`、`SignalingClient`）。测试通过接口注入 fake。

## 2. 同步模型（design.md D3）

**一笔 = 一条不可变操作（op）**，不做像素 CRDT：

```
Op(kind, opId, authorId, lamport, wallTime)
  ├─ AddStrokeOp(stroke)     一笔
  ├─ UndoOp(undoneOpId)      撤销 = 追加墓碑，只允许撤自己的 opId
  ├─ ClearCanvasOp           清空（可撤销）
  └─ AddLayer/RemoveLayer/MoveLayer/SetLayerVisible   图层操作
```

- **全序**：`(lamport, authorId)`；不变量"同一作者 lamport 严格递增"
  由 `LamportClock.tick()` 保证 → 全序成立
- **收敛**：所有端按全序重放生效 op 集（log \\ 被撤销者）得到一致状态；
  收敛性由属性测试钉死（乱序 + 重复注入）
- **幂等**：opId 去重 → 重传 / 补发 / 重连全量重发都安全
- **性能**：顺序 op 走 O(1) 快路径追加；undo/图层/乱序触发全量重放
  （500 op 重放 6ms，见 perf-baseline）
- **上限**：op-log 超 2000 条改发快照补齐；2 万条提示导出新建

## 3. 传输层（design.md D4）

```
Transport（基类：链路登记 / broadcast / sendTo / accept 缓冲队列）
  ├─ LanTransport      mDNS(_taraxacum._tcp) + TCP 长度前缀帧
  ├─ WebRtcTransport   公共 MQTT/WS 信令（AES-GCM 加密 SDP）+ 可靠有序
  │                    DataChannel（同一套信封帧）
  └─ ManualTransport   邀请码（zlib+base64url，分帧二维码）+ TCP 直连
```

- **信封**：`Envelope{type, roomId, from, to?, seq, lamport, payload}`
  统一所有消息；payload 按 type 解释（op 二进制 / roomControl JSON / …）
- **可靠有序**：TCP 天然有序；DataChannel 用可靠有序模式；两端共用
  长度前缀帧 + opId 去重
- **断开感知**：心跳 ping/pong（3s/10s）判定静默掉线；正常关闭=left、
  异常=lost，事件只从 `link.closed` 单一来源发布
- **加入选择**：`TransportSelector` 按序执行自动尝试（每步硬超时），
  全部失败进入手动邀请码流程；当前方式在房间页展示

## 4. 房间会话（design.md D6）

`RoomSession` 是**纯状态机**：输入（本端意图 / 远端 roomControl 消息）
→ 状态迁移 + outbox 消息；房主是唯一权威，任何变更广播**全量状态快照**
（带单调版本号），成员端只接受更大版本。审批 / 只读 / 容量(16) /
房主转移（按 joinOrder）/ 解散 都是状态迁移规则，全部有行为测试。

`RoomNetworkAdapter` 是会话与传输的胶水：outbox → Envelope 广播/定向；
入站 roomControl → 会话；对端断开 → 成员维护。`RoomController`
(Riverpod) 编排生命周期并把各控制器接到一起。

## 5. 实时同步管道（task 5.x）

```
CanvasController.onLocalOp ──broadcast──▶ 其他端 handleEnvelope
        │（文档本地已应用）                     │ applyRemoteOp（幂等+时钟合并）
        ▼                                     ▼
   CanvasDocument（op-log 全序重放） ◀── 同一文档模型
```

- 中途加入：房主推送全量 op-log（分片+进度）或超阈值时的状态快照
- 断线重连：成员侧检测房主失联 → `ReconnectLoop`（30s 窗口）→ 重新
  hello → 房主重推 → opId 去重无感补齐；超时提示手动重新加入
- 远端 op 应用时合并 Lamport 时钟，保证此后本地 op 全序大于远端

## 6. 渲染（design.md D2）

- 每共享图层一张离屏 `ui.Picture` 缓存，笔画完成才重录该层
- 进行中笔画画在独立动态层（不触发缓存重录）
- 橡皮 = `BlendMode.dstOut`，在所在图层 `saveLayer` 内执行 → 只擦本层
- 视图变换（缩放平移）只影响绘制矩阵；远端光标在屏幕空间绘制（恒定大小）

## 7. 已知边界

- mesh 16 人为设计容量；更大规模需要分发树（未实现）
- 无 TURN：对称 NAT 跨网打洞失败时依赖手动邀请码兜底
- 快照后成员无法撤销加入前的他人笔画（撤销只作用于自己的 op，规格如此）
- WebRTC 真机跨网连通性、公共 MQTT 中继可用性 → task 7.1 双设备验收
