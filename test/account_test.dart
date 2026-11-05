import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/core/account.dart';
import 'package:reader/core/api.dart';
import 'package:reader/core/store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 假网络层：记录请求，按路径返回预设响应。
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.respond);

  final (int, Object) Function(RequestOptions o, String body) respond;
  final requests = <(RequestOptions, String)>[];

  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? body, Future<void>? cancel) async {
    final raw = body == null ? '' : utf8.decode(await body.expand((b) => b).toList());
    requests.add((o, raw));
    final (status, json) = respond(o, raw);
    return ResponseBody.fromString(jsonEncode(json), status, headers: {
      Headers.contentTypeHeader: ['application/json; charset=utf-8'],
    });
  }

  @override
  void close({bool force = false}) {}
}

Map<String, Object?> _comic(String pw, String name) => {'path_word': pw, 'name': name, 'cover': '', 'author': [{'name': '作者'}], 'popular': 1};

Map<String, Object?> _page(List<Object?> list) => {'code': 200, 'message': 'ok', 'results': {'list': list, 'total': list.length, 'limit': 50, 'offset': 0}};

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await initStores();
    await AccountService.instance.load();
  });

  test('源站条目两种结构都能解析：作品在 comic 里 / 平铺', () {
    final a = RemoteComic.fromJson({'comic': _comic('a', 'A'), 'last_browse': {'last_browse_id': 'u1', 'last_browse_name': '第1话'}});
    expect(a.comic.pathWord, 'a');
    expect(a.chapterId, 'u1');
    expect(a.chapterName, '第1话');
    final b = RemoteComic.fromJson({..._comic('b', 'B'), 'last_chapter_id': 'u2', 'last_chapter_name': '第2话'});
    expect(b.comic.name, 'B');
    expect(b.chapterId, 'u2');
    final c = RemoteComic.fromJson({'comic': _comic('c', 'C'), 'last_browse': null});
    expect(c.chapterId, isNull);
  });

  test('登录：网页端协议，密码编码为 base64(密码-随机数)，只保存凭证', () async {
    final fake = _FakeAdapter((o, body) {
      if (o.path.endsWith('/api/v1/login')) {
        return (200, {'code': 200, 'message': '请求成功', 'results': {'token': 't0k', 'username': 'reader', 'nickname': '读者'}});
      }
      return (200, _page(const []));
    });
    MangaApi.instance.adapter = fake;
    await AccountService.instance.login('reader', 'secret');

    final (o, body) = fake.requests.first;
    expect(o.uri.toString(), startsWith('https://www.copy4000.com/api/v1/login'));
    final form = Uri.splitQueryString(body);
    expect(form['salt'], matches(RegExp(r'^\d{6}$')));
    expect(utf8.decode(base64.decode(form['password']!)), 'secret-${form['salt']}');
    expect(form['platform'], '1');

    final account = AccountService.instance;
    expect(account.loggedIn, isTrue);
    expect(account.displayName, '读者');
    // 后续会员接口带凭证。
    expect(fake.requests.skip(1).every((r) => r.$1.headers['authorization'] == 'Token t0k'), isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys().where((k) => prefs.get(k).toString().contains('secret')), isEmpty);
  });

  test('登录失败（风控 210）：原样提示，不保存任何东西', () async {
    MangaApi.instance.adapter = _FakeAdapter((o, body) => (200, {'code': 210, 'message': '請等待 1 小時自動解除', 'results': null}));
    await expectLater(AccountService.instance.login('reader', 'secret'), throwsA(isA<ApiException>().having((e) => e.message, 'message', contains('1 小時'))));
    expect(AccountService.instance.loggedIn, isFalse);
  });

  test('同步：书架加入追更，历史只补本机没有的阅读位置', () async {
    final store = LibraryStore.instance;
    // 本机已经读过 b（有页码），不应被源站历史覆盖。
    store.recordPosition(
      id: 'b',
      create: () => ShelfEntry(id: 'b', kind: ShelfKind.manga, name: 'B', cover: '', author: '', followed: false),
      chapterUuid: 'local',
      chapterName: '第9话',
      page: 5,
      pageCount: 20,
      progress: .3,
    );
    MangaApi.instance.adapter = _FakeAdapter((o, body) {
      if (o.path.endsWith('/api/v1/login')) return (200, {'code': 200, 'results': {'token': 't', 'username': 'u'}});
      if (o.path.contains('/member/collect/comics')) {
        return (200, _page([{'comic': _comic('a', 'A')}, {'comic': _comic('b', 'B')}]));
      }
      if (o.path.contains('/member/browse/comics')) {
        return (200, _page([
          {'comic': _comic('a', 'A'), 'last_browse': {'last_browse_id': 'ra', 'last_browse_name': '第3话'}},
          {'comic': _comic('b', 'B'), 'last_browse': {'last_browse_id': 'rb', 'last_browse_name': '第1话'}},
          {'comic': _comic('c', 'C'), 'last_browse': {'last_browse_id': 'rc', 'last_browse_name': '第7话'}},
        ]));
      }
      return (404, {});
    });
    await AccountService.instance.login('u', 'p');

    final r = AccountService.instance.lastReport!;
    expect(r.shelfTotal, 2);
    expect(r.shelfAdded, 2);
    expect(r.historyFilled, 2);
    expect(store.isFollowed('a'), isTrue);
    expect(store.isFollowed('b'), isTrue);
    expect(store.entry('a')!.chapterName, '第3话');
    expect(store.entry('b')!.chapterUuid, 'local');
    expect(store.entry('b')!.page, 5);
    // 只在源站历史里的作品：记位置，不追更。
    expect(store.isFollowed('c'), isFalse);
    expect(store.entry('c')!.chapterName, '第7话');
  });

  test('凭证失效（401）：清掉凭证，书架不动', () async {
    MangaApi.instance.adapter = _FakeAdapter((o, body) {
      if (o.path.endsWith('/api/v1/login')) return (200, {'code': 200, 'results': {'token': 'old', 'username': 'u'}});
      if (o.path.contains('/member/collect/comics') && LibraryStore.instance.entries.isEmpty) return (200, _page([{'comic': _comic('a', 'A')}]));
      return (401, {'detail': 'Invalid token.'});
    });
    await AccountService.instance.login('u', 'p');
    expect(AccountService.instance.loggedIn, isFalse);
    expect(AccountService.instance.error, '登录已失效，请重新登录');
  });
}
