import 'dart:convert';

import 'package:flutter/services.dart';

/// Android Storage Access Framework bridge.
/// 선택한 원본은 앱으로 이동하지 않고 URI 권한만 보존한다.
class AndroidSafService {
  static const _channel = MethodChannel('epub_reader/saf');

  static Future<String?> pickEpubFile() async =>
      _channel.invokeMethod<String>('pickEpubFile');

  static Future<String?> pickFolder() async =>
      _channel.invokeMethod<String>('pickFolder');

  static Future<String> materializeUri(String uri) async =>
      await _channel.invokeMethod<String>('materializeUri', {'uri': uri}) ??
      (throw Exception('선택한 EPUB을 읽을 수 없습니다.'));

  static Future<List<String>> listEpubUris(String treeUri) async {
    final result = await _channel.invokeMethod<String>(
      'listEpubUris',
      {'uri': treeUri},
    );
    if (result == null || result.isEmpty) return const [];
    return (jsonDecode(result) as List).cast<String>();
  }
}
