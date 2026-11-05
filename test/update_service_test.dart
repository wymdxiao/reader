import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/core/store.dart';
import 'package:reader/core/update_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 假网络层：按 host 决定返回什么，用来验证直连失败后是否切镜像。
class _MirrorAdapter implements HttpClientAdapter {
  _MirrorAdapter(this.respond);

  final (int, Object?) Function(String host) respond;
  final hosts = <String>[];

  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? body, Future<void>? cancel) async {
    hosts.add(o.uri.host);
    final (status, json) = respond(o.uri.host);
    if (status < 0) throw DioException(requestOptions: o, type: DioExceptionType.connectionTimeout);
    return ResponseBody.fromString(jsonEncode(json), status, headers: {
      Headers.contentTypeHeader: ['application/json; charset=utf-8'],
    });
  }

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> release({String tag = 'v0.3.0', List<Map<String, dynamic>>? assets, String body = '## 更新\n- 书架排序\n- **省流**画质'}) => {
      'tag_name': tag,
      'name': 'reader $tag',
      'body': body,
      'html_url': 'https://github.com/wymdxiao/reader/releases/tag/$tag',
      'published_at': '2026-11-05T08:00:00Z',
      'assets': assets ??
          [
            {'name': 'checksums.txt', 'size': 120, 'browser_download_url': 'https://example.com/checksums.txt'},
            {'name': 'reader-arm64-v8a.apk', 'size': 12000000, 'browser_download_url': 'https://example.com/arm64.apk'},
            {'name': 'reader-0.3.0.apk', 'size': 19293798, 'browser_download_url': 'https://example.com/universal.apk'},
          ],
    };

void main() {
  group('版本号', () {
    test('从 tag 里取出版本号', () {
      expect(normalizeVersion('v0.3.0'), '0.3.0');
      expect(normalizeVersion('0.3'), '0.3.0');
      expect(normalizeVersion('release-1.2.0'), '1.2.0');
      expect(normalizeVersion('v1.0.0-beta.2'), '1.0.0');
      expect(normalizeVersion('latest'), isNull);
    });

    test('按数字比较，不按字符串', () {
      expect(compareVersions('0.3.0', '0.2.0'), greaterThan(0));
      expect(compareVersions('v0.2', '0.2.0'), 0);
      expect(compareVersions('1.10.0', '1.9.9'), greaterThan(0));
      expect(compareVersions('0.2.0+5', '0.2.0'), 0);
      expect(compareVersions('0.1.9', '0.2.0'), lessThan(0));
    });
  });

  group('GitHub 响应', () {
    test('仓库还没有发布版本（404）', () {
      final r = UpdateService.resolve(404, {'message': 'Not Found'}, '0.2.0');
      expect(r.status, UpdateStatus.noRelease);
      expect(r.message, contains('还没有发布'));
    });

    test('限流（403）不当作没有更新', () {
      expect(UpdateService.resolve(403, {'message': 'API rate limit exceeded'}, '0.2.0').status, UpdateStatus.failed);
    });

    test('有新版本：优先选通用 APK，带大小和发布日期', () {
      final r = UpdateService.resolve(200, release(), '0.2.0');
      expect(r.status, UpdateStatus.available);
      expect(r.release!.version, '0.3.0');
      expect(r.release!.packageUrl, 'https://example.com/universal.apk');
      expect(r.release!.packageSize, 19293798);
      expect(r.release!.publishedAt!.toUtc(), DateTime.utc(2026, 11, 5, 8));
    });

    test('版本相同或更旧：已是最新', () {
      expect(UpdateService.resolve(200, release(tag: 'v0.2.0'), '0.2.0').status, UpdateStatus.upToDate);
      expect(UpdateService.resolve(200, release(tag: 'v0.1.0'), '0.2.0').status, UpdateStatus.upToDate);
    });

    test('没有 APK 附件时下载地址退回 Release 页面', () {
      final r = UpdateService.resolve(200, release(assets: const []), '0.2.0');
      expect(r.release!.packageUrl, isNull);
      expect(r.release!.downloadUrl, contains('/releases/tag/v0.3.0'));
    });

    test('iOS 只认 .ipa：新版本只有 APK 时不提示更新', () {
      final r = UpdateService.resolve(200, release(), '0.2.0', ext: '.ipa', requirePackage: true);
      expect(r.status, UpdateStatus.upToDate);
      expect(r.message, contains('安装包'));
      final withIpa = UpdateService.resolve(
          200,
          release(assets: [
            {'name': 'reader-0.3.0.ipa', 'size': 30000000, 'browser_download_url': 'https://example.com/a.ipa'},
          ]),
          '0.2.0',
          ext: '.ipa',
          requirePackage: true);
      expect(withIpa.status, UpdateStatus.available);
      expect(withIpa.release!.packageUrl, 'https://example.com/a.ipa');
    });

    test('标签不是版本号时报错', () {
      expect(UpdateService.resolve(200, release(tag: 'nightly'), '0.2.0').status, UpdateStatus.failed);
    });

    test('其他状态码报错并带上状态码', () {
      final r = UpdateService.resolve(400, null, '0.2.0');
      expect(r.status, UpdateStatus.failed);
      expect(r.message, contains('400'));
    });
  });

  test('Release 说明去掉 Markdown 记号', () {
    expect(plainNotes('## 更新\n- 书架排序\n* **省流**画质\n\n\n\n`fix`'), '更新\n• 书架排序\n• 省流画质\n\nfix');
  });

  group('镜像源', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await initStores();
      UpdateService.instance.currentForTest = '0.2.0';
      ReaderPrefs.instance.skipVersion = '';
    });

    test('直连可用就不走镜像', () async {
      final fake = _MirrorAdapter((host) => host == 'api.github.com' ? (200, release()) : (200, release(tag: 'v9.9.9')));
      UpdateService.instance.adapter = fake;
      final r = await UpdateService.instance.check();
      expect(r.status, UpdateStatus.available);
      expect(fake.hosts, ['api.github.com']);
    });

    test('直连超时就换镜像，拿到的是镜像返回的版本', () async {
      final fake = _MirrorAdapter((host) => host == 'api.github.com' ? (-1, null) : (200, release(tag: 'v0.4.0')));
      UpdateService.instance.adapter = fake;
      final r = await UpdateService.instance.check();
      expect(fake.hosts.first, 'api.github.com');
      expect(fake.hosts.length, 2);
      expect(r.status, UpdateStatus.available);
      expect(r.release!.version, '0.4.0');
    });

    test('镜像返回 200 但不是 Release 内容，继续判定为失败而不是当成新版本', () async {
      final fake = _MirrorAdapter((host) => (200, {'error': 'rate limited'}));
      UpdateService.instance.adapter = fake;
      final r = await UpdateService.instance.check();
      expect(r.status, UpdateStatus.failed);
      expect(r.release, isNull);
    });

    test('404 是 GitHub 的明确回答，不再试镜像', () async {
      final fake = _MirrorAdapter((host) => (404, {'message': 'Not Found'}));
      UpdateService.instance.adapter = fake;
      final r = await UpdateService.instance.check();
      expect(r.status, UpdateStatus.noRelease);
      expect(fake.hosts.length, 1);
    });

    test('自动检查：开关关掉就完全不请求', () async {
      final fake = _MirrorAdapter((host) => (200, release(tag: 'v0.4.0')));
      UpdateService.instance.adapter = fake;
      ReaderPrefs.instance.autoUpdate = false;
      expect(await UpdateService.instance.autoCheck(), isNull);
      expect(fake.hosts, isEmpty);
    });

    test('自动检查：开关打开且有新版本时返回结果', () async {
      final fake = _MirrorAdapter((host) => (200, release(tag: 'v0.4.0')));
      UpdateService.instance.adapter = fake;
      ReaderPrefs.instance.autoUpdate = true;
      ReaderPrefs.instance.lastUpdateCheck = 0;
      final r = await UpdateService.instance.autoCheck();
      expect(r, isNotNull);
      expect(r!.release!.version, '0.4.0');
    });

    test('自动检查：刚查过 10 分钟内不重复请求', () async {
      final fake = _MirrorAdapter((host) => (200, release(tag: 'v0.4.0')));
      UpdateService.instance.adapter = fake;
      ReaderPrefs.instance.autoUpdate = true;
      ReaderPrefs.instance.lastUpdateCheck = DateTime.now().millisecondsSinceEpoch;
      expect(await UpdateService.instance.autoCheck(), isNull);
      expect(fake.hosts, isEmpty);
    });

    test('自动检查：被跳过的版本不再提示', () async {
      final fake = _MirrorAdapter((host) => (200, release(tag: 'v0.4.0')));
      UpdateService.instance.adapter = fake;
      ReaderPrefs.instance.autoUpdate = true;
      ReaderPrefs.instance.lastUpdateCheck = 0;
      ReaderPrefs.instance.skipVersion = '0.4.0';
      expect(await UpdateService.instance.autoCheck(), isNull);
    });
  });
}
