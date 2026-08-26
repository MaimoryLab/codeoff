<p align="center">
  <img src="assets/codeoff_logo.png" alt="Codeoff logo" width="128">
</p>

<h1 align="center">Codeoff Mobile</h1>

<p align="center">
  <a href="https://github.com/MaimoryLab/codeoff/actions/workflows/ci-test.yml"><img src="https://github.com/MaimoryLab/codeoff/actions/workflows/ci-test.yml/badge.svg" alt="Flutter tests"></a>
  <a href="https://github.com/MaimoryLab/codeoff/actions/workflows/build-android.yml"><img src="https://github.com/MaimoryLab/codeoff/actions/workflows/build-android.yml/badge.svg" alt="Android build"></a>
  <a href="README.md">English</a>
</p>

Codeoff Mobile 是一个 Flutter 移动客户端，用于连接本地 Codeoff 桌面桥接服务。与 Codeoff Server 配对后，可以在手机上控制 Codex：浏览线程、启动或恢复任务、发送 turn、上传文件，以及处理审批请求。

客户端使用 Dart 标准库 `HttpClient` 和 WebSocket 会话与桥接服务通信，不依赖第三方网络或状态管理框架。

## 快速开始

### 环境要求

- Flutter stable，Dart SDK `3.13` 或更高版本
- 正在运行的 Codeoff Server 桌面应用，并已启用 app-server 和 Cloudflare Tunnel
- Android 或 iOS 真机/模拟器

### 从源码运行

```sh
flutter pub get
flutter run
```

### 配对设备

1. 启动 Codeoff Server，并启用 Cloudflare Tunnel。
2. 从桌面面板复制 Tunnel 地址和一次性配对码。
3. 在 Codeoff Mobile 中输入这两项并点击 **Pair**。
4. 保存返回的设备令牌，后续重新连接时会使用它。令牌会保存在设备安全存储中。

### 检查与构建

```sh
dart analyze
flutter test --no-pub
flutter build apk --release
```

`Build Android APK` 工作流会在推送 `v*.*.*` 标签或手动运行时构建 Android release APK。

## 相关项目

- [Codeoff Server](https://github.com/MaimoryLab/codeoff-server)：桌面桥接、本地 API、Codex app-server 和 Cloudflare Tunnel。

## 许可证

[Apache License 2.0](LICENSE)
