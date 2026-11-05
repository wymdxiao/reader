import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import 'config.dart';
import 'store.dart';
import 'api.dart' show ApiException;

/// GitHub Releases 上的一个版本。
class AppRelease {
  const AppRelease({
    required this.version,
    required this.tag,
    required this.title,
    required this.notes,
    required this.pageUrl,
    this.packageUrl,
    this.packageSize,
    this.publishedAt,
  });

  /// 不带 v 的版本号，例如 `0.3.0`。
  final String version;
  final String tag;
  final String title;
  final String notes;
  final String pageUrl;

  /// 当前平台的安装包（Android 为 .apk，iOS 为 .ipa）。
  final String? packageUrl;
  final int? packageSize;
  final DateTime? publishedAt;

  /// 下载地址：有安装包附件就直接下载，否则打开 Release 页面。
  String get downloadUrl => packageUrl ?? pageUrl;

  /// 解析 `GET /repos/{owner}/{repo}/releases/latest` 的响应；不是合法版本号时返回 null。
  /// [ext] 为当前平台安装包的扩展名。
  static AppRelease? fromJson(Map<String, dynamic> j, {String ext = '.apk'}) {
    final tag = (j['tag_name'] ?? '').toString().trim();
    final version = normalizeVersion(tag);
    if (version == null) return null;
    final assets = (j['assets'] is List ? j['assets'] as List : const [])
        .whereType<Map>()
        .where((a) => (a['name'] ?? '').toString().toLowerCase().endsWith(ext))
        .toList();
    // 多个 APK 时优先通用包，其次 arm64（真机最常见）。
    assets.sort((a, b) => _apkRank(a['name'].toString()).compareTo(_apkRank(b['name'].toString())));
    final apk = assets.firstOrNull;
    return AppRelease(
      version: version,
      tag: tag,
      title: (j['name'] ?? '').toString().trim().isEmpty ? tag : j['name'].toString().trim(),
      notes: (j['body'] ?? '').toString().trim(),
      pageUrl: (j['html_url'] ?? AppConfig.githubPage).toString(),
      packageUrl: apk?['browser_download_url']?.toString(),
      packageSize: apk?['size'] is int ? apk!['size'] as int : null,
      publishedAt: DateTime.tryParse((j['published_at'] ?? '').toString())?.toLocal(),
    );
  }

  static int _apkRank(String name) {
    final n = name.toLowerCase();
    if (n.contains('universal') || !RegExp('arm|x86|x64').hasMatch(n)) return 0;
    if (n.contains('arm64')) return 1;
    return 2;
  }
}

enum UpdateStatus { available, upToDate, noRelease, failed }

class UpdateResult {
  const UpdateResult(this.status, {required this.current, this.release, this.message});

  final UpdateStatus status;
  final String current;
  final AppRelease? release;
  final String? message;
}

/// 从 tag 里取出 `主.次.修订` 版本号：`v0.3.0`、`0.3`、`release-1.2.0` 都可以；取不出返回 null。
String? normalizeVersion(String tag) {
  final m = RegExp(r'(\d+)(?:\.(\d+))?(?:\.(\d+))?').firstMatch(tag);
  if (m == null) return null;
  return [m.group(1), m.group(2) ?? '0', m.group(3) ?? '0'].map((s) => int.parse(s!)).join('.');
}

/// 比较两个版本号：a > b 返回正数。忽略 `+build` 和预发布后缀。
int compareVersions(String a, String b) {
  List<int> parts(String v) => (normalizeVersion(v) ?? '0.0.0').split('.').map(int.parse).toList();
  final x = parts(a), y = parts(b);
  for (var i = 0; i < 3; i++) {
    if (x[i] != y[i]) return x[i] - y[i];
  }
  return 0;
}

class UpdateService {
  UpdateService._();

  static final instance = UpdateService._();

  final _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 15),
    headers: {'Accept': 'application/vnd.github+json', 'User-Agent': 'reader'},
    // 404（还没有发布版本）和 403（限流）自己处理，不当作异常。
    validateStatus: (s) => s != null && s < 500,
  ));

  String? _current;

  /// 测试里替换网络层。
  @visibleForTesting
  set adapter(HttpClientAdapter a) => _dio.httpClientAdapter = a;

  Future<String> currentVersion() async => _current ??= (await PackageInfo.fromPlatform()).version;

  /// 测试里替换当前版本号。
  @visibleForTesting
  set currentForTest(String v) => _current = v;

  /// iOS 只认带 .ipa 附件的版本，避免把只发了 APK 的版本推给 iOS 用户。
  static bool get _ios => defaultTargetPlatform == TargetPlatform.iOS;

  Future<UpdateResult> check() async {
    final current = await currentVersion();
    final prefs = ReaderPrefs.instance;
    Object? lastError;
    var lastStatus = 0;
    // 依次尝试：直连 → 镜像。任何一台拿到合法响应就停。
    for (final base in AppConfig.githubApiMirrors) {
      try {
        final res = await _dio.get<Object>('$base${AppConfig.releasesApi}');
        lastStatus = res.statusCode ?? 0;
        final body = res.data is String ? jsonDecode(res.data as String) : res.data;
        // 镜像可能返回 200 但内容不是 Release（例如错误页），当作这台不可用。
        if (lastStatus == 200 && body is Map && body['tag_name'] != null) {
          prefs.lastUpdateCheck = DateTime.now().millisecondsSinceEpoch;
          return resolve(lastStatus, body, current, ext: _ios ? '.ipa' : '.apk', requirePackage: _ios);
        }
        // 404/403 是 GitHub 的明确回答，直接按它给结论，不再换镜像。
        if (lastStatus == 404 || lastStatus == 403 || lastStatus == 429) {
          return resolve(lastStatus, body, current, ext: _ios ? '.ipa' : '.apk', requirePackage: _ios);
        }
        lastError = res.data;
      } on DioException catch (e) {
        lastError = e;
      } on FormatException catch (e) {
        lastError = e;
      }
    }
    final msg = switch (lastError) {
      DioException(type: DioExceptionType.connectionTimeout || DioExceptionType.receiveTimeout) => '连接 GitHub 超时，请检查网络或代理',
      DioException() => '无法连接 GitHub，请检查网络或代理',
      _ => '更新检测返回了无法识别的内容',
    };
    return UpdateResult(UpdateStatus.failed, current: current, message: msg);
  }

  /// 根据 HTTP 状态和响应体得出结论（单独拿出来便于测试）。
  /// [requirePackage] 为 true 时，新版本没有对应安装包就视为“已是最新”。
  static UpdateResult resolve(int status, Object? body, String current, {String ext = '.apk', bool requirePackage = false}) {
    if (status == 404) {
      return UpdateResult(UpdateStatus.noRelease, current: current, message: '仓库还没有发布版本');
    }
    if (status == 403 || status == 429) {
      return UpdateResult(UpdateStatus.failed, current: current, message: 'GitHub 请求太频繁，请过一会儿再试');
    }
    if (status != 200 || body is! Map) {
      return UpdateResult(UpdateStatus.failed, current: current, message: 'GitHub 返回异常（HTTP $status）');
    }
    final release = AppRelease.fromJson(Map<String, dynamic>.from(body), ext: ext);
    if (release == null) {
      return UpdateResult(UpdateStatus.failed, current: current, message: '最新 Release 的标签不是版本号');
    }
    final newer = compareVersions(release.version, current) > 0;
    if (newer && requirePackage && release.packageUrl == null) {
      return UpdateResult(UpdateStatus.upToDate, current: current, release: release, message: 'v${release.version} 还没有本平台的安装包');
    }
    return UpdateResult(newer ? UpdateStatus.available : UpdateStatus.upToDate, current: current, release: release);
  }

  /// 启动自动检查的节流：同一版本号查过就不再查，但换了版本号或隔了一天会重查。
  /// 用户要求「每次进入软件自动检测」，所以这里不再用 24 小时硬性拦截，
  /// 改成 10 分钟内不重复请求，避免冷启动几次就撞 GitHub 限流。
  static const autoInterval = Duration(minutes: 10);

  /// 下载安装包，返回本地文件。依次尝试直连和各镜像。
  ///
  /// [onProgress] 收到 0–1 的进度；总大小未知时传 null。
  Future<File> download(AppRelease release, {void Function(double? progress)? onProgress}) async {
    final url = release.packageUrl;
    if (url == null) throw const ApiException('这个版本没有安装包');
    final dir = await getTemporaryDirectory();
    final name = url.split('/').last.split('?').first;
    final file = File('${dir.path}/$name');
    Object? lastError;
    for (final base in AppConfig.githubDownloadMirrors) {
      // 已经是完整地址的镜像只拼在前面；直连是空前缀。
      final full = base.isEmpty ? url : '$base$url';
      try {
        await _dio.download(
          full,
          file.path,
          deleteOnError: true,
          onReceiveProgress: (got, total) => onProgress?.call(total > 0 ? got / total : null),
        );
        if (await file.length() > 1024) return file;
        lastError = const ApiException('下载到的文件不完整');
      } on DioException catch (e) {
        lastError = e;
        if (await file.exists()) await file.delete();
      }
    }
    throw ApiException(switch (lastError) {
      DioException(type: DioExceptionType.connectionTimeout || DioExceptionType.receiveTimeout) => '下载超时，请切换到其他线路再试',
      DioException() => '下载失败，请检查网络或代理',
      ApiException(message: final m) => m,
      _ => '下载失败',
    });
  }

  /// 启动时自动检查：开关关掉就不查；10 分钟内查过不重复查。
  /// 有新版本且没被跳过时返回结果，否则返回 null。
  Future<UpdateResult?> autoCheck() async {
    final prefs = ReaderPrefs.instance;
    if (!prefs.autoUpdate) return null;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - prefs.lastUpdateCheck < autoInterval.inMilliseconds) return null;
    final r = await check();
    if (r.status != UpdateStatus.available) return null;
    if (r.release!.version == prefs.skipVersion) return null;
    return r;
  }
}

/// Release 说明是 Markdown；弹窗里只需要可读的纯文本：去掉标题井号、把列表符号换成圆点。
String plainNotes(String md) => md
    .split('\n')
    .map((l) => l.trimRight())
    .map((l) => l.replaceFirst(RegExp(r'^#{1,6}\s*'), ''))
    .map((l) => l.replaceFirst(RegExp(r'^\s*[-*+]\s+'), '• '))
    .map((l) => l.replaceAll(RegExp(r'\*\*|__|`'), ''))
    .join('\n')
    .replaceAll(RegExp(r'\n{3,}'), '\n\n')
    .trim();
