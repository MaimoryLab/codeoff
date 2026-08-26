import 'dart:async';

import 'package:flutter/material.dart';

import 'app.dart';
import 'local_notifications.dart';

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
        processingSummaryFromThread,
        shouldNotifyThreadMessage;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  unawaited(LocalNotifications.instance.initialize());
  runApp(const CodeoffApp());
}
