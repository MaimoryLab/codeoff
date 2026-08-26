<p align="center">
  <img src="assets/codeoff_logo.png" alt="Codeoff logo" width="128">
</p>

<h1 align="center">Codeoff Mobile</h1>

<p align="center">
  <a href="https://github.com/MaimoryLab/codeoff/actions/workflows/ci-test.yml"><img src="https://github.com/MaimoryLab/codeoff/actions/workflows/ci-test.yml/badge.svg" alt="Flutter tests"></a>
  <a href="https://github.com/MaimoryLab/codeoff/actions/workflows/build-android.yml"><img src="https://github.com/MaimoryLab/codeoff/actions/workflows/build-android.yml/badge.svg" alt="Android build"></a>
  <a href="README.zh-CN.md">中文</a>
</p>

Codeoff Mobile is a Flutter client for the local Codeoff desktop bridge. Pair it with Codeoff Server to control Codex from a phone: browse threads, start or resume work, send turns, upload files, and respond to approval requests.

The client talks to the bridge with Dart's standard `HttpClient` and a WebSocket session. No third-party networking or state-management package is required.

## Quickstart

### Requirements

- Flutter stable with Dart SDK `3.13` or newer
- A running Codeoff Server desktop app with its app-server and Cloudflare Tunnel enabled
- An Android or iOS device/emulator

### Run from source

```sh
flutter pub get
flutter run
```

### Pair a device

1. Start Codeoff Server and enable its Cloudflare Tunnel.
2. Copy the tunnel endpoint and one-time pairing code from the desktop panel.
3. Enter both values in Codeoff Mobile and tap **Pair**.
4. Keep the returned device token for later reconnects. The app stores it in secure device storage.

### Check and build

```sh
dart analyze
flutter test --no-pub
flutter build apk --release
```

Android release APKs are built by the `Build Android APK` workflow for version tags (`v*.*.*`) or manual runs.

## Related project

- [Codeoff Server](https://github.com/MaimoryLab/codeoff-server): desktop bridge, local API, Codex app-server, and Cloudflare Tunnel.

## License

[Apache License 2.0](LICENSE)
