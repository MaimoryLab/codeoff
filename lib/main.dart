import 'package:flutter/material.dart';

import 'app.dart';

export 'app.dart';
export 'home/remote_home_page.dart'
    show
        activeTurnIdFrom,
        compareRemoteThreads,
        externalHttpUri,
        parseRemoteTimestamp,
        shouldRefreshRemoteHistory;

void main() => runApp(const CodexRemoteApp());
