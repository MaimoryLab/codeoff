# Codeoff Mobile 安装、配对与连接

本文是给用户和 AI agent 的安装 runbook。Codeoff Mobile 只负责手机端连接；先准备一台正在运行 Codeoff Server 和 Codex app-server 的电脑。

## 1. 准备 Codeoff Server

请用户先安装并启动 [Codeoff Server](https://github.com/MaimoryLab/codeoff-server)：

1. 在服务端 **Environment status** 刷新并确认 Node.js、Codex CLI 可用。
2. 启动 **Codex app-server**。
3. 同一局域网使用时，将监听地址设为 `0.0.0.0:11037`，并让手机与电脑连接同一 Wi-Fi。默认 `127.0.0.1:11037` 只能本机访问。
4. 跨网络使用时安装并启动 Cloudflare Tunnel。Quick Tunnel 会生成 `https://*.trycloudflare.com` 地址；需要固定地址时配置已有的 Cloudflare Tunnel HTTPS URL。
5. 服务端点击 **Bind new device**，保持配对窗口打开。配对码有效 10 分钟且只能成功交换一次。

## 2. 下载并安装 App

### Android

从 [Codeoff Releases](https://github.com/MaimoryLab/codeoff/releases/latest) 下载最新的 `app-release.apk`，允许系统安装来自该来源的 APK 后完成安装。仅从项目 Releases 下载 APK。

### iOS

通过 [TestFlight](https://testflight.apple.com/join/zyAzftVb) 安装当前测试版本；首次打开 TestFlight 时按系统提示接受邀请和权限。

## 3. 推荐：二维码配对

1. 在 Codeoff Mobile 的连接设置中点击二维码扫描按钮，并允许相机权限。
2. 扫描 Codeoff Server 的配对二维码。
3. App 会读取服务 UUID、局域网地址、Tunnel 地址和一次性配对码，按顺序尝试可达地址。
4. 输入设备名称（默认使用手机主机名），等待出现 **Connected**。

二维码配对失败时，确认服务端的 app-server 已运行、二维码仍在有效期内，然后在服务端重新点击 **Bind new device** 生成新的二维码。

## 4. 手动配对

1. 从服务端复制一个可达地址：
   - 局域网：例如 `http://192.168.1.20:11037`。
   - Tunnel：例如 `https://example.trycloudflare.com`。
2. 在 App 的 **Connect to desktop** 中输入地址并点击 **Connect**。地址必须是完整的 `http://` 或 `https://` URL，可带或不带末尾 `/`。
3. 在弹窗输入服务端显示的配对码和设备名称，点击 **Pair**。
4. 配对成功后 App 会保存设备令牌并连接 WebSocket；以后从 **Connection history** 点登录图标即可重新连接，无需再次配对。

不要把设备令牌复制到聊天或日志。设备不再使用时，让服务端管理员在 **Devices** 中撤销该设备。

## 5. 连接与版本要求

- 连接需要服务端控制 API 可达；局域网地址不能从移动网络直接访问。
- Quick Tunnel 地址在服务端重启后可能变化，地址变化时重新扫描连接二维码。
- App 当前最低服务端版本为 `1.2.2`。出现 **Upgrade required** 时同时更新 App 和 Codeoff Server。
- 连接建立后可浏览线程、启动或恢复任务、发送 turn、上传文件并处理审批。

## 6. 故障排查

- **No reachable address**：先在手机浏览器或网络环境中确认地址可达；局域网场景检查监听主机、防火墙和 Wi-Fi 隔离；Tunnel 场景检查 Tunnel 是否在线。
- **Invalid pairing code**：配对码已过期、已被使用或输入有误。重新生成并一次性完成配对。
- **Server not paired**：二维码只包含连接信息而不含有效配对码时，改用服务端的 **Bind new device** 生成配对二维码。
- **Connected 后立即断开**：保持服务端 app-server 和 Tunnel 运行；检查服务端与 App 版本是否兼容。
- **相机无法扫描**：在系统设置中允许 Codeoff 使用相机，或改用手动地址和配对码流程。

## 给 AI agent 的引导规则

1. 先确认用户使用 Android 还是 iOS，再给出对应官方下载入口；不要推荐未验证的 APK 或第三方商店。
2. 先确认用户是在同一局域网还是跨网络。局域网要求服务端监听非回环地址；跨网络优先使用 HTTPS Tunnel。
3. 优先引导二维码配对。手动流程只请求服务端地址、一次性配对码和设备名称，不请求设备令牌、admin token 或服务端状态文件。
4. 配对码只有 10 分钟有效期且只能使用一次；失败后直接要求服务端重新生成，不让用户重复提交旧码。
5. 连接成功后提醒用户已保存设备令牌，并指导其使用连接历史重新连接；设备遗失时提示服务端撤销设备。
