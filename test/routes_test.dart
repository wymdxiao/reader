import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/core/api.dart';
import 'package:reader/core/config.dart';
import 'package:reader/core/routes.dart';
import 'package:reader/core/store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 按 host 决定行为的假网络层：返回正常 JSON、业务失败或抛网络错误。
class _HostAdapter implements HttpClientAdapter {
  _HostAdapter(this.respond);

  final (Map<String, Object?>, int) Function(String host, RequestOptions o) respond;
  final hosts = <String>[];

  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? body, Future<void>? cancel) async {
    final host = o.uri.host;
    hosts.add(host);
    final (json, status) = respond(host, o);
    if (status < 0) {
      throw DioException(requestOptions: o, type: DioExceptionType.connectionTimeout, message: 'timeout');
    }
    return ResponseBody.fromString(jsonEncode(json), status, headers: {
      Headers.contentTypeHeader: ['application/json; charset=utf-8'],
    });
  }

  @override
  void close({bool force = false}) {}
}

Map<String, Object?> _page() => {'code': 200, 'message': 'ok', 'results': {'list': [], 'total': 0, 'limit': 20, 'offset': 0}};

String _hostOf(String base) => Uri.parse(base).host;

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await initStores();
    RouteSelector.instance.reset();
    ReaderPrefs.instance.apiMode = 0;
    ReaderPrefs.instance.apiCustom = '';
    ReaderPrefs.instance.apiRoute = AppConfig.routes.first.id;
  });

  group('基址规范化', () {
    test('补协议、去尾斜杠、去掉空白', () {
      expect(RouteSelector.normalizeBase('  api.example.com  '), 'https://api.example.com');
      expect(RouteSelector.normalizeBase('https://a.b/'), 'https://a.b');
      expect(RouteSelector.normalizeBase('http://a.b///'), 'http://a.b');
      expect(RouteSelector.normalizeBase(''), '');
      expect(RouteSelector.normalizeBase('   '), '');
    });
  });

  group('候选顺序', () {
    test('自动：三条线路的所有域名都在，测速后直连线路里最快的排第一', () {
      final s = RouteSelector.instance;
      final all = [for (final r in AppConfig.routes) ...r.hosts];
      expect(s.candidates().toSet(), all.toSet());
      expect(s.candidates().first, all.first); // 没测速时按线路表顺序

      s.reportSuccess('https://mapi.fgjfghkk.club', 220);
      s.reportSuccess('https://mapi.hotmangasf.com', 270);
      // Cloudflare 线路即使更快也不抢直连线路的位置
      expect(s.activeBase, 'https://mapi.hotmangasf.com');

      s.reportSuccess('https://mapi.hotmangasg.com', 120);
      expect(s.activeBase, 'https://mapi.hotmangasg.com');
    });

    test('直连线路全部冷却：才退到 Cloudflare 线路', () {
      final s = RouteSelector.instance;
      final direct = AppConfig.routes.firstWhere((r) => r.direct).hosts;
      final cf = AppConfig.routes.firstWhere((r) => !r.direct).hosts;
      for (final h in direct) {
        s.reportFailure(h);
      }
      s.reportSuccess(cf.first, 900);
      expect(s.activeBase, cf.first);
      // 冷却没到期时直连线路排在后面
      expect(s.candidates().indexOf(direct.first), greaterThan(s.candidates().indexOf(cf.first)));
    });

    test('固定线路：只用选中的那条', () {
      final s = RouteSelector.instance;
      ReaderPrefs.instance.apiRoute = 'club';
      ReaderPrefs.instance.apiMode = 1;
      final club = AppConfig.routes.firstWhere((r) => r.id == 'club').hosts;
      expect(s.candidates().toSet(), club.toSet());
      // 冷却与延迟只在组内排序，不会跳到别的线路
      s.reportFailure(club.first);
      expect(s.candidates().toSet(), club.toSet());
      expect(s.candidates().last, club.first);
    });

    test('自定义基址：只用自己的地址', () {
      final s = RouteSelector.instance;
      ReaderPrefs.instance.apiMode = 2;
      ReaderPrefs.instance.apiCustom = 'proxy.example.com/';
      expect(s.candidates(), ['https://proxy.example.com']);
      expect(s.usingCustom, isTrue);
      expect(s.activeHost, 'proxy.example.com');
    });

    test('自定义模式但没填：退回自动，不会发给空地址', () {
      final s = RouteSelector.instance;
      ReaderPrefs.instance.apiMode = 2;
      expect(s.usingCustom, isFalse);
      expect(s.candidates(), isNotEmpty);
      expect(s.candidates().every((h) => h.startsWith('https://') && h.length > 10), isTrue);
    });

    test('失败的主机冷却 60 秒，排在最后，过期后恢复', () {
      final s = RouteSelector.instance;
      final base = AppConfig.routes.first.hosts.first;
      s.reportSuccess(base, 100);
      expect(s.candidates().first, base);
      s.reportFailure(base);
      expect(s.candidates().last, base);
      // 手动把冷却时间往前推，模拟 60 秒过去
      s.health[base]!.coolUntil = DateTime.now().subtract(const Duration(seconds: 1));
      expect(s.candidates().first, base);
    });
  });

  group('请求层', () {
    test('一台超时就换下一台，成功后记住这台', () async {
      final s = RouteSelector.instance;
      final first = AppConfig.routes.first.hosts.first;
      final second = AppConfig.routes.first.hosts[1];
      final fake = _HostAdapter((host, o) => host == _hostOf(first) ? (<String, Object?>{}, -1) : (_page(), 200));
      MangaApi.instance.adapter = fake;

      await MangaApi.instance.comics(limit: 1);
      expect(fake.hosts.first, _hostOf(first));
      expect(fake.hosts[1], _hostOf(second));
      expect(s.activeBase, second);
      expect(s.health[first]!.cooling(DateTime.now()), isTrue);
    });

    test('results 为 null：换线路没用，只发一次请求就报错', () async {
      final s = RouteSelector.instance;
      var calls = 0;
      MangaApi.instance.adapter = _HostAdapter((host, o) {
        calls++;
        return ({'code': 200, 'message': '操作成功', 'results': null}, 200);
      });

      await expectLater(MangaApi.instance.comics(limit: 1), throwsA(isA<ApiException>()));
      expect(calls, 1);
      expect(s.health, isEmpty); // 不算主机的网络问题，不冷却
      expect(MangaApi.instance.lastError.value!.message, contains('数据源拒绝请求'));
    });

    test('带凭证的 401 抛凭证失效，不冷却主机', () async {
      final s = RouteSelector.instance;
      MangaApi.instance.adapter = _HostAdapter((host, o) => ({'detail': 'Invalid token.'}, 401));

      await expectLater(MangaApi.instance.collectedComics('t'), throwsA(isA<AuthExpired>()));
      expect(s.health.values.any((h) => h.cooling(DateTime.now())), isFalse);
    });

    test('所有主机都超时：抛网络错误，全部冷却', () async {
      final s = RouteSelector.instance;
      MangaApi.instance.adapter = _HostAdapter((host, o) => (<String, Object?>{}, -1));

      await expectLater(MangaApi.instance.comics(limit: 1), throwsA(isA<ApiException>()));
      expect(s.health.values.every((h) => h.cooling(DateTime.now())), isTrue);
    });
  });
}
