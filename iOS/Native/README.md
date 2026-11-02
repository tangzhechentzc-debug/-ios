# iPhone 原生定位连接层

本模块为本项目独立编写，通过 MIT 许可的 [idevice](https://github.com/jkcoxson/idevice/tree/89702099f4d7552f704f93b4526756abda319ceb) 调用 iOS 27 开发者服务。没有复制 WrapPin 产品代码，也不启动 Mac/Python 后端。

依赖固定到提交 `89702099f4d7552f704f93b4526756abda319ceb`，传递依赖由 Cargo.lock 固定；分发时一并包含 THIRD_PARTY_NOTICES.txt。上游许可证见 LICENSE-idevice.txt。TLS 使用 ring 和 idevice 自带的 TLS-PSK 实现，不依赖 OpenSSL 或 MITM 证书。

## 构建

```sh
iOS/Native/build.sh all
cargo test --manifest-path iOS/Native/Cargo.toml --lib --locked
```

需要 Rust 与 Xcode。脚本只为子进程设置 DEVELOPER_DIR，不更改系统 xcode-select。输出 `lib/iphoneos/libchangelocation.a` 和 `lib/iphonesimulator/libchangelocation.a`，均为 arm64，最低 iOS 27.0。构建产物与 target 不提交。

## Swift/C 接口

`cl_request(const char *)` 接受 UTF-8 JSON，返回已分配的 UTF-8 JSON；每次必须调用 `cl_free`。在后台串行队列调用。任何请求和响应都不能记日志，因为配对响应包含私钥或一次性代码。所有响应至少含 `ok:Bool,state:String,message:String`。

- `pair_start`：建立 TCP 监听，返回 `port,service_name,txt`。Swift 使用 NetService 在 `local.` 发布 `_remotepairing-pairable-host._tcp.`。配对会话最多 300 秒。
- `pair_status`：返回 `pairing_state:waiting|code|complete|failed|idle`。`code` 时有 `pairing_code`，只能在当前设备显示或用本地通知提示；`complete` 时有 `pairing_record` 和 `peer_identifier`。将 opaque `pairing_record` 存入本机钥匙串，再取消轮询并调用 `pair_cancel` 释放临时内存。不要把配对记录写入 Documents、UserDefaults、诊断日志或源码。
- `pair_cancel`：停止监听；Swift 同时停止 Bonjour 发布。不会删除已经保存在钥匙串的记录。
- `match_service`：请求携带 `pairing_record,service_identifier,auth_tag`，结果 `matched`。后两者来自 `_remotepairing._tcp.` 的 TXT `identifier` 与 `authTag`（base64 字符串）。使用已配对设备的 IRK 验证轮换的 mDNS 身份，不能按设备名称或固定 UUID 猜测匹配。
- `connect`：携带上述字段以及 `host:"10.7.0.1",port:<Bonjour解析端口>,recovery_needed:Bool`。只允许 LocalDevVPN 的本机设备通道；验证已有配对，不自动尝试新的配对。建立 TLS-PSK/CDTunnel、用户态 TCP、RSD、DVT LocationSimulation 通道，但不设置或清除位置。配对、通道和 DVT 操作均有超时。空闲 ready 会话在再次 connect 时重新建立通道，不能把缓存状态当作新的连接检测；仅仍在模拟的活动会话复用，以免检查动作中断模拟。
- `apply`：携带 `latitude,longitude`，WGS-84 且须为合法有限数。保持同一定位会话，并每 5 秒刷新当前模拟位置。成功状态 `active`；命令不确定或会话故障为 `unknown`。
- `clear`：以 `expects_reply=false` 发送 `stopLocationSimulation`，不等候或误读停止回复。随后在相同 DVT 传输上开一个只读服务通道，利用关联消息 ID 的往返确认此前字节已到达远端，再结束 worker、DVT 和用户态隧道。成功状态为 `stopped_unverified`，恢复义务仍保留；这不证明系统已重新获得真实 GPS。失败保持 `unknown`。再次停止须先 `connect(recovery_needed:true)`。
- `confirm_restore`：仅在当前进程成功发送过停止请求且会话已结束后接受。必须由用户在地图确认真实位置恢复后主动触发；成功返回 `idle` 并解除恢复义务。进程重启后没有内存中的停止凭据，需重新连接、发送停止请求，再确认。
- `status`：返回进程内会话状态；不是重新进行网络探测。活动会话保持任务发现失败会更新为 unknown，已终止的工作任务不会继续报告 ready/active。
- `disconnect`：只在清理义务已解除时关闭通道，否则拒绝。不得用断开或强制退出冒充停止恢复。

Swift 应在发送 apply 之前持久化恢复标记；进程重启时传 `recovery_needed:true` 重新连接并执行 clear，用户确认地图真实位置恢复且 `confirm_restore` 成功后才删除标记。Swift 还负责 iOS 后台执行、定位权限、本地通知、应用生命周期和 Keychain；本模块不会绕过 iOS 调度限制。后台挂起、隧道中断和恢复都必须真机核验。

当前六个自动测试覆盖坐标拒绝、配对身份不匹配时禁止连接、失败重连保留恢复义务、ready 缓存不能代替新的连接检测、停止后确认状态守卫，以及使用假 DVT 对端验证停止报文不要求回复且无需回复即可返回；编译与这些测试不能替代真机配对、定位、更新、后台和清除验证。

停止协议依据：本机 pymobiledevice3 及其[官方实现](https://github.com/doronz88/pymobiledevice3/blob/master/pymobiledevice3/services/dvt/instruments/location_simulation.py)将 `stopLocationSimulation` 标为 `expects_reply=False`。固定版本 idevice 的封装要求回复并忽略内容，因此本模块仅替换 LocationSimulation 的薄通道封装，保留上游传输实现。这个协议修正与停止后释放会话需真机复测；尚未据此确认用户此前未恢复的唯一原因。
