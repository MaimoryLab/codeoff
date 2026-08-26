import 'dart:async';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

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

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  unawaited(LocalNotifications.instance.initialize());
  runApp(CodeoffApp(version: (await PackageInfo.fromPlatform()).version));
}
