import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Google Drive와 로컬 폴더를 양방향으로 동기화한다.
///
/// 앱의 EPUB 라이브러리 DB와 분리된 계층이다. 원본 파일을 이동하지 않고
/// 지정한 폴더 자체를 기준으로 동기화하므로 기존 라이브러리 구조와 충돌하지 않는다.
class GoogleDriveSyncService {
  static const _scopes = <String>[drive.DriveApi.driveScope];
  static const _folderMime = 'application/vnd.google-apps.folder';
  static const _stateVersion = 1;

  final GoogleSignIn _signIn = GoogleSignIn.instance;
  drive.DriveApi? _drive;
  GoogleSignInAccount? _account;
  bool _initialized = false;

  Future<void> _initialize() async {
    if (_initialized) return;
    const serverClientId = String.fromEnvironment('GOOGLE_SERVER_CLIENT_ID');
    await _signIn.initialize(
      serverClientId: serverClientId.isEmpty ? null : serverClientId,
    );
    _initialized = true;
  }

  Future<GoogleSignInAccount> signIn() async {
    await _initialize();
    final account = await _signIn.authenticate();
    final authorization = await account.authorizationClient.authorizeScopes(_scopes);
    _drive = drive.DriveApi(authorization.authClient(scopes: _scopes));
    _account = account;
    return account;
  }

  Future<GoogleSignInAccount?> tryRestoreSession() async {
    await _initialize();
    final account = await _signIn.attemptLightweightAuthentication();
    if (account == null) return null;

    final authorization = await account.authorizationClient.authorizationForScopes(_scopes);
    if (authorization == null) return null;
    _drive = drive.DriveApi(authorization.authClient(scopes: _scopes));
    _account = account;
    return account;
  }

  GoogleSignInAccount? get account => _account;
  bool get isConnected => _drive != null;

  Future<void> signOut() async {
    _drive = null;
    _account = null;
    await _initialize();
    await _signIn.signOut();
  }

  Future<drive.DriveApi> _api() async {
    if (_drive != null) return _drive!;
    await tryRestoreSession();
    final api = _drive;
    if (api == null) {
      throw StateError('Google Drive에 연결되어 있지 않습니다.');
    }
    return api;
  }

  /// 지정한 Drive 폴더의 바로 아래 폴더/파일을 반환한다.
  Future<List<drive.File>> listChildren(String folderId) async {
    final api = await _api();
    final result = <drive.File>[];
    String? pageToken;
    do {
      final response = await api.files.list(
        q: "'$folderId' in parents and trashed = false",
        pageSize: 1000,
        pageToken: pageToken,
        orderBy: 'folder,name_natural',
        spaces: 'drive',
        supportsAllDrives: true,
        includeItemsFromAllDrives: true,
        $fields: 'nextPageToken,files(id,name,mimeType,parents,modifiedTime,size,md5Checksum,trashed)',
      );
      result.addAll(response.files ?? const []);
      pageToken = response.nextPageToken;
    } while (pageToken != null);
    return result;
  }

  /// Drive 폴더 전체를 상대경로 -> 메타데이터로 평탄화한다.
  Future<Map<String, drive.File>> _readDriveTree(String rootId) async {
    final result = <String, drive.File>{};
    final queue = <({String id, String path})>[(id: rootId, path: '')];

    while (queue.isNotEmpty) {
      final current = queue.removeAt(0);
      final children = await listChildren(current.id);
      for (final child in children) {
        final name = child.name;
        final relative = current.path.isEmpty ? name! : p.join(current.path, name!);
        result[relative] = child;
        if (child.mimeType == _folderMime && child.id != null) {
          queue.add((id: child.id!, path: relative));
        }
      }
    }
    return result;
  }

  Future<String> _findOrCreateDriveFolder(
    drive.DriveApi api,
    String parentId,
    String name,
  ) async {
    final response = await api.files.list(
      q: "'$parentId' in parents and name = '${_escapeQuery(name)}' and mimeType = '$_folderMime' and trashed = false",
      pageSize: 10,
      spaces: 'drive',
      supportsAllDrives: true,
      includeItemsFromAllDrives: true,
      $fields: 'files(id,name)',
    );
    final existing = response.files?.firstOrNull;
    if (existing?.id != null) return existing!.id!;

    final created = await api.files.create(
      drive.File(name: name, mimeType: _folderMime, parents: [parentId]),
      supportsAllDrives: true,
      $fields: 'id,name',
    );
    return created.id!;
  }

  Future<String> _ensureDrivePath(
    drive.DriveApi api,
    String rootId,
    String relativeDirectory,
  ) async {
    if (relativeDirectory.isEmpty || relativeDirectory == '.') return rootId;
    var parent = rootId;
    for (final segment in p.split(relativeDirectory)) {
      if (segment.isEmpty || segment == '.') continue;
      parent = await _findOrCreateDriveFolder(api, parent, segment);
    }
    return parent;
  }

  Future<List<FileSystemEntity>> _localEntries(String root) async {
    final directory = Directory(root);
    if (!await directory.exists()) {
      throw FileSystemException('동기화할 폴더가 없습니다.', root);
    }
    return directory.list(recursive: true, followLinks: false).toList();
  }

  Future<String> _md5(File file) async => (await md5.bind(file.openRead()).first).toString();

  Future<void> _downloadFile(
    drive.DriveApi api,
    drive.File remote,
    File destination,
  ) async {
    final parent = await destination.parent.create(recursive: true);
    if (!await parent.exists()) return;

    final result = await api.files.get(
      remote.id!,
      supportsAllDrives: true,
      downloadOptions: drive.DownloadOptions.fullMedia,
    );
    if (result is! drive.Media) {
      throw StateError('Drive 파일을 다운로드할 수 없습니다: ${remote.name}');
    }

    final temp = File('${destination.path}.epub_sync_tmp');
    if (await temp.exists()) await temp.delete();
    final sink = temp.openWrite();
    try {
      await result.stream.pipe(sink);
    } catch (_) {
      await sink.close();
      if (await temp.exists()) await temp.delete();
      rethrow;
    }
    await sink.close();
    if (await destination.exists()) await destination.delete();
    await temp.rename(destination.path);
  }

  Future<drive.File> _uploadFile(
    drive.DriveApi api,
    File local,
    String parentId, {
    String? existingId,
  }) async {
    final length = await local.length();
    final media = drive.Media(
      local.openRead(),
      length,
      contentType: 'application/epub+zip',
    );
    final metadata = drive.File(
      name: p.basename(local.path),
      mimeType: 'application/epub+zip',
      parents: existingId == null ? [parentId] : null,
    );

    if (existingId == null) {
      return api.files.create(
        metadata,
        uploadMedia: media,
        supportsAllDrives: true,
        $fields: 'id,name,mimeType,parents,modifiedTime,size,md5Checksum',
      );
    }
    return api.files.update(
      metadata,
      existingId,
      uploadMedia: media,
      supportsAllDrives: true,
      $fields: 'id,name,mimeType,parents,modifiedTime,size,md5Checksum',
    );
  }

  Future<File> _stateFile() async {
    final dir = await getApplicationSupportDirectory();
    return File(p.join(dir.path, 'google_drive_sync_state.json'));
  }

  Future<Map<String, dynamic>> _loadState() async {
    final file = await _stateFile();
    if (!await file.exists()) return {'version': _stateVersion, 'roots': {}};
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {}
    return {'version': _stateVersion, 'roots': {}};
  }

  Future<void> _saveState(Map<String, dynamic> state) async {
    final file = await _stateFile();
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(const JsonEncoder.withIndent('  ').convert(state));
    if (await file.exists()) await file.delete();
    await temp.rename(file.path);
  }

  /// 로컬 폴더 ↔ Drive 폴더 전체를 동기화한다.
  ///
  /// - 처음에는 전체 트리를 1회 비교한다.
  /// - 이후에는 저장된 크기/수정시각/해시를 사용해 변경된 파일만 전송한다.
  /// - 양쪽이 동시에 변경된 경우 로컬 파일을 `.sync-conflict-날짜`로 보존한 뒤
  ///   Drive 버전을 원래 경로에 내려 데이터 손실을 피한다.
  /// - 삭제는 기본적으로 전파하지 않는다. 한쪽에서 실수로 삭제해도 다음 동기화에서
  ///   파일이 살아 있는 쪽을 기준으로 복구할 수 있도록 하는 안전한 정책이다.
  Future<DriveSyncResult> syncFolder({
    required String localRoot,
    required String driveFolderId,
  }) async {
    final api = await _api();
    final localRootPath = p.normalize(localRoot);
    final localEntities = await _localEntries(localRootPath);
    final driveTree = await _readDriveTree(driveFolderId);
    final state = await _loadState();
    final roots = Map<String, dynamic>.from(state['roots'] as Map? ?? {});
    final stateKey = '$localRootPath::$driveFolderId';
    final previous = Map<String, dynamic>.from(roots[stateKey] as Map? ?? {});
    final entries = Map<String, dynamic>.from(previous['entries'] as Map? ?? {});

    var uploaded = 0;
    var downloaded = 0;
    var conflicts = 0;
    var unchanged = 0;

    final localFiles = <String, File>{};
    for (final entity in localEntities) {
      if (entity is! File) continue;
      final relative = p.relative(entity.path, from: localRootPath);
      if (p.basename(entity.path).endsWith('.epub_sync_tmp')) continue;
      localFiles[relative] = entity;
    }

    final allPaths = <String>{...localFiles.keys, ...driveTree.keys};
    final sortedPaths = allPaths.toList()..sort();

    for (final relative in sortedPaths) {
      final local = localFiles[relative];
      final remote = driveTree[relative];
      final old = Map<String, dynamic>.from(entries[relative] as Map? ?? {});

      if (remote?.mimeType == _folderMime) continue;

      if (local != null && remote == null) {
        final parent = await _ensureDrivePath(api, driveFolderId, p.dirname(relative));
        final created = await _uploadFile(api, local, parent);
        final digest = await _md5(local);
        entries[relative] = _entry(
          driveId: created.id!,
          local: local,
          localMd5: digest,
          remote: created,
        );
        uploaded++;
        continue;
      }

      if (local == null && remote != null) {
        if (remote.id == null) continue;
        final destination = File(p.join(localRootPath, relative));
        if (remote.mimeType == _folderMime) {
          await destination.create(recursive: true);
          continue;
        }
        await _downloadFile(api, remote, destination);
        entries[relative] = _entry(
          driveId: remote.id!,
          local: destination,
          localMd5: await _md5(destination),
          remote: remote,
        );
        downloaded++;
        continue;
      }

      if (local == null || remote == null || remote.id == null) continue;
      if (remote.mimeType == _folderMime) continue;

      final localStat = await local.stat();
      final localModified = localStat.modified.millisecondsSinceEpoch;
      final localSize = localStat.size;
      final previousLocalModified = (old['localModified'] as num?)?.toInt();
      final previousLocalSize = (old['localSize'] as num?)?.toInt();
      final previousRemoteModified = DateTime.tryParse(old['remoteModified']?.toString() ?? '');
      final remoteModified = remote.modifiedTime;

      final localChanged = previousLocalModified == null ||
          previousLocalSize == null ||
          localModified != previousLocalModified ||
          localSize != previousLocalSize;
      final remoteChanged = previousRemoteModified == null ||
          (remoteModified != null && remoteModified.millisecondsSinceEpoch != previousRemoteModified.millisecondsSinceEpoch);

      if (!localChanged && !remoteChanged) {
        unchanged++;
        continue;
      }

      final localDigest = await _md5(local);
      if (remote.md5Checksum != null && localDigest == remote.md5Checksum) {
        entries[relative] = _entry(
          driveId: remote.id!,
          local: local,
          localMd5: localDigest,
          remote: remote,
        );
        unchanged++;
        continue;
      }

      if (localChanged && !remoteChanged) {
        final updated = await _uploadFile(api, local, p.dirname(remote.parents?.first ?? driveFolderId), existingId: remote.id);
        entries[relative] = _entry(
          driveId: updated.id!,
          local: local,
          localMd5: localDigest,
          remote: updated,
        );
        uploaded++;
        continue;
      }

      if (!localChanged && remoteChanged) {
        await _downloadFile(api, remote, local);
        entries[relative] = _entry(
          driveId: remote.id!,
          local: local,
          localMd5: await _md5(local),
          remote: remote,
        );
        downloaded++;
        continue;
      }

      // 양쪽 모두 변경된 경우: 로컬 버전을 보존하고 Drive 버전을 원래 이름으로 받는다.
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final conflict = File('${local.path}.sync-conflict-$stamp.epub');
      await local.copy(conflict.path);
      await _downloadFile(api, remote, local);
      entries[relative] = _entry(
        driveId: remote.id!,
        local: local,
        localMd5: await _md5(local),
        remote: remote,
      );
      conflicts++;
    }

    roots[stateKey] = {
      'driveFolderId': driveFolderId,
      'localRoot': localRootPath,
      'syncedAt': DateTime.now().toUtc().toIso8601String(),
      'entries': entries,
    };
    state['version'] = _stateVersion;
    state['roots'] = roots;
    await _saveState(state);

    return DriveSyncResult(
      uploaded: uploaded,
      downloaded: downloaded,
      conflicts: conflicts,
      unchanged: unchanged,
    );
  }

  Map<String, dynamic> _entry({
    required String driveId,
    required File local,
    required String localMd5,
    required drive.File remote,
  }) {
    return {
      'driveId': driveId,
      'localSize': local.lengthSync(),
      'localModified': local.statSync().modified.millisecondsSinceEpoch,
      'localMd5': localMd5,
      'remoteModified': remote.modifiedTime?.toUtc().toIso8601String(),
      'remoteMd5': remote.md5Checksum,
    };
  }

  String _escapeQuery(String value) => value.replaceAll('\\', '\\\\').replaceAll("'", "\\'");
}

class DriveSyncResult {
  const DriveSyncResult({
    required this.uploaded,
    required this.downloaded,
    required this.conflicts,
    required this.unchanged,
  });

  final int uploaded;
  final int downloaded;
  final int conflicts;
  final int unchanged;

  int get changed => uploaded + downloaded;
}
