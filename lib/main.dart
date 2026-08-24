import 'package:flutter/material.dart';

import 'app.dart';

export 'app.dart';
export 'home/remote_home_page.dart'
    show
        activeTurnIdFrom,
        approvalDetailsFrom,
        approvalThreadIdFrom,
        compareRemoteThreads,
        externalHttpUri,
        parseRemoteTimestamp,
        processingSummaryFromItem,
        processingSummaryFromThread;

void main() => runApp(const CodexRemoteApp());
