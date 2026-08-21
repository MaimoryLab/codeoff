# Codex Remote Mobile

Flutter client for the local Codex Remote desktop bridge.

1. Start the desktop app and start its Cloudflare Tunnel.
2. Copy the tunnel endpoint and one-time pairing code from the desktop panel.
3. Enter both in the mobile app and tap `Pair`.
4. Use the returned device token to reconnect later, list or start threads, send turns, and answer approval requests.

Run checks locally:

```sh
dart analyze
flutter test --no-pub
```

The client uses Dart's standard `HttpClient`; no third-party networking or state-management package is required.
