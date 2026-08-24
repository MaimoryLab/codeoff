import 'package:flutter/material.dart';

import 'app.dart';

export 'app.dart';
export 'home/remote_home_page.dart'
    show
        activeTurnIdFrom,
        compareRemoteThreads,
        externalHttpUri,
        parseRemoteTimestamp,
        processingSummaryFromItem,
        processingSummaryFromThread;

void main() => runApp(const CodexRemoteApp());
