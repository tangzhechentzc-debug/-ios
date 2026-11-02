# 定位助手 · iPhone

原生 iPhone 定位模拟 App，SwiftUI + MapKit 界面，通过 Rust 原生连接层调用开发者定位服务。当前版本 1.0.1（build 2），最低 iOS 27，使用侧载签名与外部 LocalDevVPN。

支持地图选点、地点搜索、经纬度输入、WGS‑84 / GCJ‑02 转换、本机配对、设置和更新模拟位置、停止及恢复确认。配对记录仅保存于本机钥匙串。运行时不依赖 Mac 后端。

## 构建与使用

需要完整 Xcode 27+、Rust 和 XcodeGen。在仓库根目录执行：

```sh
./script/build_ios.sh device
```

输出未签名 IPA：`dist/ChangeLocation-iPhone-unsigned.ipa`，通过 iLoader 或 SideStore 签装。完整准备与使用步骤见 [iPhone 使用说明](iOS/README.md)。

## 目录

- `iOS/App/`：SwiftUI 界面、配对、设备发现、连接和恢复状态管理。
- `iOS/Native/`：Rust 原生连接层、C ABI、依赖锁文件与第三方许可。
- `Sources/ChangeLocation/Models/Coordinates.swift`：共享坐标转换。
- `Tests/iOS/`、`iOS/Tests/`：状态逻辑与原生接口测试。
- `script/`：构建和测试脚本。

## 验证

```sh
./script/test_ios_model.sh
cargo test --manifest-path iOS/Native/Cargo.toml --lib --locked
./script/build_ios.sh test
```

最后一项需要已安装的 iPhone 模拟器运行时。上传前已有 18 项主机状态逻辑检查、6 项 Rust 测试及设备/模拟器测试目标构建通过记录；模拟器 XCTest 尚未实际运行。1.0.1 真机启动、配对保留和只读连接检查已通过，完整独立设置→更新→停止恢复场景尚未复测。

停止请求发送成功不代表真实 GPS 已恢复；须在 Apple 地图核对当前位置蓝点，再点击“已确认恢复”。未恢复时可再次停止。后台与长时间锁屏行为不作保证。

## 许可证

项目使用 [Apache-2.0](LICENSE)。原生依赖 idevice 为 MIT 许可，版本固定；详见 [第三方许可](iOS/Native/THIRD_PARTY_NOTICES.txt)。
