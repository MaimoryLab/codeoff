part of '../home/remote_home_page.dart';

typedef AppRelease = ({String version, String downloadUrl, String? sha256});

const _latestReleaseUrl =
    'https://api.github.com/repos/MaimoryLab/codeoff/releases/latest';

AppRelease parseGitHubRelease(Object? value) {
  if (value is! Map) throw const FormatException('Invalid GitHub release');
  final tag = value['tag_name'];
  if (tag is! String || !tag.startsWith('v')) {
    throw const FormatException('Invalid GitHub release tag');
  }
  final version = tag.substring(1);
  compareRemoteVersions(version, version);

  final assets = value['assets'];
  if (assets is List) {
    for (final asset in assets.whereType<Map>()) {
      final name = asset['name'];
      final downloadUrl = asset['browser_download_url'];
      final uri = downloadUrl is String ? Uri.tryParse(downloadUrl) : null;
      if (name is! String ||
          !name.toLowerCase().endsWith('.apk') ||
          uri == null ||
          uri.scheme != 'https' ||
          uri.host != 'github.com') {
        continue;
      }
      final digest = asset['digest'];
      final sha256 =
          digest is String &&
              RegExp(r'^sha256:[0-9a-fA-F]{64}$').hasMatch(digest)
          ? digest.substring(7)
          : null;
      return (version: version, downloadUrl: downloadUrl, sha256: sha256);
    }
  }
  throw const FormatException('GitHub release has no APK');
}

Future<AppRelease> fetchLatestGitHubRelease() async {
  final client = HttpClient();
  final uri = Uri.parse(_latestReleaseUrl);
  try {
    final request = await client.getUrl(uri);
    request.headers
      ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
      ..set(HttpHeaders.userAgentHeader, 'Codeoff Android');
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('GitHub returned ${response.statusCode}', uri: uri);
    }
    return parseGitHubRelease(jsonDecode(body));
  } finally {
    client.close(force: true);
  }
}

extension _AppUpdate on _RemoteHomePageState {
  Future<void> checkForUpdate() =>
      _run(context.t('checkingForUpdates'), () async {
        final currentVersion = (await packageInfo).version;
        final release = await fetchLatestGitHubRelease();
        if (!mounted) return;
        if (compareRemoteVersions(release.version, currentVersion) <= 0) {
          _toast(context.t('upToDate'));
          return;
        }

        final install = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(context.t('updateAvailable')),
            content: Text(
              context.t('updateDescription', {
                'current': currentVersion,
                'latest': release.version,
              }),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(context.t('cancel')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(context.t('downloadAndInstall')),
              ),
            ],
          ),
        );
        if (install != true || !mounted) return;

        await for (final event in OtaUpdate().execute(
          release.downloadUrl,
          destinationFilename: 'codeoff-${release.version}.apk',
          sha256checksum: release.sha256,
        )) {
          if (!mounted) return;
          if (event.status == OtaStatus.DOWNLOADING) {
            _setMessage(
              context.t('downloadingUpdate', {'progress': event.value ?? '0'}),
            );
          } else if (event.status == OtaStatus.INSTALLING ||
              event.status == OtaStatus.INSTALLATION_DONE) {
            _setMessage(context.t('installingUpdate'));
          } else {
            throw StateError(
              event.value?.isNotEmpty == true
                  ? event.value!
                  : context.t('updateFailed'),
            );
          }
        }
      });
}
