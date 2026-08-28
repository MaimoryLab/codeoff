<p align="center">
  <img src="assets/codeoff_logo.png" alt="Codeoff logo" width="128">
</p>

<h1 align="center">Codeoff Mobile</h1>

<p align="center">
  <a href="https://github.com/MaimoryLab/codeoff/actions/workflows/ci-test.yml"><img src="https://github.com/MaimoryLab/codeoff/actions/workflows/ci-test.yml/badge.svg" alt="Flutter tests"></a>
  <a href="https://github.com/MaimoryLab/codeoff/actions/workflows/build-android.yml"><img src="https://github.com/MaimoryLab/codeoff/actions/workflows/build-android.yml/badge.svg" alt="Android build"></a>
  <a href="https://github.com/MaimoryLab/codeoff/releases/latest"><img src="https://img.shields.io/github/v/release/MaimoryLab/codeoff?display_name=tag&sort=semver" alt="Latest release"></a>
  <a href="https://github.com/MaimoryLab/codeoff"><img src="https://img.shields.io/github/stars/MaimoryLab/codeoff?style=flat&label=Codeoff%20Mobile" alt="Codeoff Mobile repository"></a>
</p>
<p align="center">
  <a href="README.md">English</a>
</p>


Codeoff Mobile 是一个 Flutter 移动客户端，用于连接本地 Codeoff 桌面桥接服务。与 Codeoff Server 配对后，可以在手机上控制 Codex：浏览线程、启动或恢复任务、发送 turn、上传文件，以及处理审批请求。

客户端使用 Dart 标准库 `HttpClient` 和 WebSocket 会话与桥接服务通信，不依赖第三方网络或状态管理框架。

## 截图

<table align="center">
    <tr>
      <td><img src="docs/screenshots/recents.png" alt="Codeoff Mobile 最近对话" width="603"></td>
      <td><img src="docs/screenshots/sidebar.png" alt="Codeoff Mobile 侧边栏" width="603"></td>
      <td><img src="docs/screenshots/conversation.png" alt="Codeoff Mobile 对话" width="603"></td>
      <td><img src="docs/screenshots/workdir.png" alt="Codeoff Mobile 工作区文件" width="603"></td>
    </tr>
    <tr>
      <td><img src="docs/screenshots/preview-code.png" alt="Codeoff Mobile 代码预览" width="603"></td>
      <td><img src="docs/screenshots/preview-image.png" alt="Codeoff Mobile 图片预览" width="603"></td>
      <td><img src="docs/screenshots/diff.png" alt="Codeoff Mobile 差异预览" width="603"></td>
      <td><img src="docs/screenshots/approval.png" alt="Codeoff Mobile 审批请求" width="603"></td>
    </tr>
</table>

## 工作原理

1. Codeoff Server 启动本地 Codex app-server，并通过 Cloudflare Tunnel 发布控制 API。
2. 移动端使用一次性配对码交换设备令牌。
3. 应用通过 `/api/v1/ws` 建立鉴权 WebSocket 会话；请求 ID 用于匹配响应，服务端事件也通过同一连接推送。
4. 设备令牌保存在安全存储中，后续可以直接重新连接，无需再次配对。

## 快速开始

### 使用

#### 1. 安装并配置 Codeoff Server

先安装并启动 [Codeoff Server](https://github.com/MaimoryLab/codeoff-server)：

1. 安装 Node.js 和 Codex CLI。
2. 需要从局域网外连接手机时安装 `cloudflared`；仅在局域网内使用时可以跳过。
3. 在 Codeoff Server 中启动 Codex app-server。需要远程访问时启动 Cloudflare Tunnel；需要固定地址时再配置自定义域名。
4. 需要让长时间运行的任务不因系统休眠中断时，在 Codeoff Server 菜单栏菜单中启用 **防止系统休眠**。

#### 2. 安装 Codeoff Mobile

##### Android

从 [Releases](https://github.com/MaimoryLab/codeoff/releases/latest) 页面下载最新的 `app-release.apk`，并安装到 Android 设备。

##### iOS

通过 [TestFlight](https://testflight.apple.com/join/zyAzftVb) 安装当前版本。

#### 3. 配对并连接

推荐使用二维码配对：

1. 在 Codeoff Server 中点击 **绑定新设备**。
2. 在 Codeoff Mobile 中点击二维码扫描按钮，扫描配对二维码。
3. 应用会自动读取服务地址和一次性配对码，完成设备配对并自动连接。

手动配对：

1. 从 Codeoff Server 复制监听地址或 Tunnel 地址以及配对码。
2. 在 Codeoff Mobile 中输入地址并点击 **连接**。
3. 按提示输入配对码和设备名称。

配对完成后，设备令牌会保存在安全存储中，后续可以直接重新连接。

### 开发

#### 环境要求

- Flutter stable，Dart SDK `3.13` 或更高版本
- Android 或 iOS 真机/模拟器
- 用于端到端配对测试的 Codeoff Server

#### 运行与检查

```sh
flutter pub get
flutter run
dart analyze
flutter test --no-pub
```

本地构建 Android release APK：`flutter build apk --release`。推送 `v*.*.*` 标签时，`Build Android APK` 工作流会将 APK 发布到 GitHub Releases。

## 相关项目

- [Codeoff Server](https://github.com/MaimoryLab/codeoff-server)：桌面桥接、本地 API、Codex app-server 和 Cloudflare Tunnel。

## 许可证

[Apache License 2.0](LICENSE)
