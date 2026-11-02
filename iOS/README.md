# 定位助手 · iPhone

本项目的原生 iPhone 版本。最低 iOS 27；使用免费侧载签名和外部 LocalDevVPN。Mac 版及其 Python 后端保持独立。

## 功能

- MapKit 搜索、触摸选点、经纬度输入，复用现有 WGS‑84 / GCJ‑02 转换。
- 在 iPhone 上通过系统开发者模式配对，配对记录保存至本机钥匙串。
- 通过 LocalDevVPN 与本机开发者定位服务通信；支持设置、连续更新和停止模拟。
- 定位服务检查不设置或清除位置。配对就绪、VPN 连接与定位服务连接分别判断。
- 发送位置前持久化恢复标记；停止后关闭定位会话，保留待核验状态并支持再次停止。只有用户在地图核验并点击“已确认恢复”后，才移除恢复标记。

## 构建

需要完整 Xcode 27+、Rust、XcodeGen。构建脚本通过 `DEVELOPER_DIR` 使用 Xcode，不修改系统的 `xcode-select`。

```sh
script/build_ios.sh device
script/build_ios.sh simulator
script/test_ios_model.sh
```

- 工程：`iOS/ChangeLocation.xcodeproj`，Scheme `ChangeLocationiOS`。
- 项目配置：`iOS/project.yml`；构建时重新运行 XcodeGen。
- 设备产物：`dist/ChangeLocation-iPhone-unsigned.ipa`。
- 原生库的依赖固定在 `Native/Cargo.toml` 和 `Native/Cargo.lock`；首次构建会安装所需 Rust iOS target 并下载依赖。
- `test_ios_model.sh` 在 Mac 上编译并运行同一份 App 状态逻辑，使用替身设备服务。它验证恢复、失败和坐标处理，不代表手机实测。
- `script/build_ios.sh test` 执行 iOS XCTest，需要已安装的 iPhone 模拟器运行时；可用 `SIMULATOR_ID` 指定设备。

## 签装与首次使用

使用 iLoader 的 Import IPA 对未签名 IPA 签名并安装，也可以使用已正常登录的 SideStore。应用标识为 `com.tzchen.ChangeLocation`，显示名称为“定位助手”。不需要付费 Network Extension 权限。

免费开发者签名通常最多同时安装三个 App。安装工具如提示名额已满，须由用户选择要移除的 App；不能自动删除应用或吊销证书。本项目不会接管 WrapPin 的应用标识、配对记录或数据。

1. 打开 LocalDevVPN 并连接；保持 Wi‑Fi 和系统开发者模式开启。
2. 打开“定位助手” → 连接 → 配对这台 iPhone。允许本地网络、使用期间定位及配对通知。
3. 前往系统设置 → 隐私与安全性 → 开发者模式，与 ChangeLocation 配对。先输入手机解锁密码，再输入本 App 或通知中的配对码。整个过程在手机上连续完成。
4. 返回 App，检查定位服务。检查成功后搜索地点或输入坐标，开始模拟。
5. 用 Apple 地图的当前位置蓝点核验。结束时点击“停止模拟”，等待停止请求发送和会话关闭；确认 Apple 地图真实位置恢复后，返回本 App 点“已确认恢复”。如果未恢复，使用“再次停止”。本 App 的地图图钉只表示选中坐标，停止后仍会保留。

系统可能限制后台执行。App 使用定位后台模式在切换到设置、地图时保持会话，但不保证长时间锁屏下的持续运行。App 进入状态未知后须先停止恢复，不能把强制退出视作恢复成功。待确认恢复时重开 App，也会保留恢复提示；不自动推断真实 GPS 已恢复。

## 实现与边界

SwiftUI 界面通过后台串行队列调用 Rust C ABI。原生引擎基于 MIT 许可的 [idevice 固定提交](https://github.com/jkcoxson/idevice/tree/89702099f4d7552f704f93b4526756abda319ceb)，在进程内建立 Remote Pairing → TLS‑PSK → RSD → DVT LocationSimulation 通道，不依赖 Mac 发命令。

发现服务后使用已保存 IRK 验证 Bonjour 轮换身份，并固定连接 LocalDevVPN 本机地址 `10.7.0.1`。自定义 VPN 地址或蜂窝网络建连不属于当前最小版本的验收范围。

原生接口与许可证说明见 [Native/README.md](Native/README.md)。IPA 包含 `THIRD_PARTY_NOTICES.txt`。未复制 WrapPin 产品代码。

当前验证范围见 [仓库说明](../README.md#验证)。第三方应用的测试结果不能替代本 App 的真机验证。
