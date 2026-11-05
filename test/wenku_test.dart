import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fast_gbk/fast_gbk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/core/wenku.dart';
import 'package:reader/core/wenku_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 站点结构照真实页面写；正文和书名都是自己编的，不用源站内容。
const _catalogHtml = '''
<table class="css" border="0" cellpadding="3" cellspacing="1">
<tr>
  <td class="vcss" colspan="4" vid="163301">第一卷 教程样本</td>
</tr>
<tr>
  <td class="ccss"><a href="163302.htm">序章 开端</a></td>
  <td class="ccss"><a href="163303.htm">第一章 第一节</a></td>
</tr>
<tr>
  <td class="vcss" colspan="4" vid="165776">第二卷 续编</td>
</tr>
<tr>
  <td class="ccss"><a href="170001.htm">第二章 第二节</a></td>
</tr>
</table>
''';

const _contentHtml = '''
<html><body>
<h1>序章　开端</h1>
<div id="content">
本文来自 轻小说文库(http://www.wenku8.com)<br />
<br />
　　第一段正文，用来验证段落切分。<br />
<br />
　　第二段正文。<br />
<img src="https://pic.wenku8.cn/pictures/1/2/3.jpg" /><br />
　　第三段正文。<br />
<img src="https://evil.example.com/track.gif" />
</div>
<a href="160000.htm">上一章</a>
<a href="163303.htm">下一章</a>
</body></html>
''';

/// 结构照 2026-11 实测的搜索结果页（书名、作者为自编）：书名在 <b><a> 里，作者在其后的「作者:xxx/分类:」。
const _searchHtml = '''
<div id="content"><table class="grid"><caption>“样本”搜索结果</caption><tbody><tr><td>
<div style="width:373px;"><div style="width:95px;float:left;"><a href="/book/471.htm" tiptitle="样本长篇（上）"><img src="http://img.wenku8.com/image/0/471/471s.jpg"></a></div>
<div style="margin-top:2px;"><b><a style="font-size:13px;" href="/book/471.htm" target="_blank" tiptitle="样本长篇（上）">样本长篇（上）</a></b>
<p>作者:样本作者甲/分类:样本文库</p><p>连载中</p><p class="hottext">公告:因版权问题，该书已经下架！</p></div></div>
<div style="width:373px;"><div style="width:95px;float:left;"><a href="https://www.wenku8.net/book/1990.htm"><img src="http://img.wenku8.com/image/1/1990/1990s.jpg"></a></div>
<div style="margin-top:2px;"><b><a style="font-size:13px;" href="https://www.wenku8.net/book/1990.htm" target="_blank">样本外传</a></b>
<p>作者:样本作者乙/分类:样本文库</p><p>更新:2025-11-27/字数:1566K/连载中</p>
<p><a href="/book/1990.htm" target="_blank">我要阅读</a> | <a href="/modules/article/addbookcase.php?bid=1990">加入书架</a></p></div></div>
<div style="width:373px;"><div style="margin-top:2px;"><b><a href="/book/471.htm">样本长篇（上）</a></b><p>作者:样本作者甲/分类:样本文库</p></div></div>
</td></tr></tbody></table></div>
<div id="left"><a href="/book/3933.htm">侧栏里的书架链接</a></div>
''';

const _shelfHtml = '''
<table class="css">
<tr><td>标题</td><td>作者</td></tr>
<tr>
  <td><input type="checkbox" name="checkid[]" value="13346167"></td>
  <td><a href="/book/3933.htm">样本小说</a></td>
  <td>样本作者</td>
  <td>插图</td>
  <td></td>
  <td>26-11-02</td>
  <td><a href="javascript:bookcase.php?classid=0&delid=13346167">移除</a></td>
</tr>
<tr>
  <td><input type="checkbox" name="checkid[]" value="13346168"></td>
  <td><a href="/book/4455.htm">样本小说二</a></td>
  <td>另一个作者</td>
  <td>第三章</td>
  <td>第二章</td>
  <td>26-10-30</td>
  <td><a href="javascript:bookcase.php?classid=0&delid=13346168">移除</a></td>
</tr>
</table>
<a href="/logout.php">退出</a>
''';

List<int> _utf8Bytes(String s) => utf8.encode(s);
List<int> _gbkBytes(String s) => gbk.encode(s);

/// 假网络层：按路径返回预设页面，响应体用 GBK 编码（和真实站点一致）。
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.respond);

  final ResponseBody Function(RequestOptions o) respond;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? body, Future<void>? cancel) async {
    requests.add(o);
    return respond(o);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _html(String text, {int status = 200, Map<String, List<String>>? headers, bool gbkEncoded = true}) =>
    ResponseBody.fromBytes(
      gbkEncoded ? _gbkBytes(text) : _utf8Bytes(text),
      status,
      headers: {
        Headers.contentTypeHeader: ['text/html; charset=gbk'],
        ...?headers,
      },
    );

/// 登录成功后源站会种下的两个 Cookie。
const _loginCookies = {
  'set-cookie': [
    'PHPSESSID=0000sample0000; path=/',
    'jieqiUserInfo=jieqiUserId%3D1; expires=Thu, 01-Jan-2037 00:00:00 GMT; path=/',
  ],
};

void main() {
  group('编码', () {
    test('GBK 字节能解回中文', () {
      expect(decodeGbk(_gbkBytes('刀剑神域')), '刀剑神域');
    });

    test('UTF-8 字节也能认出来（部分页面会回 UTF-8）', () {
      expect(decodeGbk(_utf8Bytes('刀剑神域')), '刀剑神域');
    });

    test('搜索关键词按 GBK 编码后再 URL 编码', () {
      // 「刀」的 GBK 是 B5 B6。
      expect(encodeGbkQuery('刀'), '%B5%B6');
    });
  });

  group('目录解析', () {
    final c = parseCatalog(_catalogHtml, aid: 3933, cls: 3);

    test('卷和章都取到', () {
      expect(c.volumes.length, 2);
      expect(c.volumes.first.name, '第一卷 教程样本');
      expect(c.chapters.length, 3);
      expect(c.chapters.first.cid, 163302);
      expect(c.chapters.first.name, '序章 开端');
    });

    test('章归到最近的卷，序号连续', () {
      expect(c.chapters.map((e) => e.volume).toList(), [0, 0, 1]);
      expect(c.chapters.map((e) => e.index).toList(), [0, 1, 2]);
      expect(c.volumes[1].chapters.single.cid, 170001);
    });
  });

  group('正文解析', () {
    final content = parseContent(_contentHtml);

    test('去掉水印和空行，保留段落', () {
      expect(content.paragraphs.first, '第一段正文，用来验证段落切分。');
      expect(content.paragraphs.length, 4); // 三段正文 + 插图占位
      expect(content.paragraphs.join(), isNot(contains('本文来自')));
      expect(content.paragraphs.join(), isNot(contains('&nbsp;')));
    });

    test('只保留站点图床的插图', () {
      expect(content.images, ['https://pic.wenku8.cn/pictures/1/2/3.jpg']);
    });

    test('上一章 / 下一章', () {
      expect(content.previous, 160000);
      expect(content.next, 163303);
    });

    test('插图章节：每张图包在 divimage 里，全部取到，水印去掉', () {
      final c = parseContent('<div id="content" style="font-size: 16px;"> <ul id="contentdp">本文来自 轻小说文库</ul> '
          '<div class="divimage"><a href="https://pic.777743.xyz/1/1/1/1.jpg"><img src="https://pic.777743.xyz/1/1/1/1.jpg" border="0" class="imagecontent"></a></div>'
          '<div class="divimage"><a href="https://pic.777743.xyz/1/1/1/2.jpg"><img src="https://pic.777743.xyz/1/1/1/2.jpg" border="0" class="imagecontent"></a></div>'
          '</div><img src="https://ads.example.com/a.gif">');
      expect(c.images, ['https://pic.777743.xyz/1/1/1/1.jpg', 'https://pic.777743.xyz/1/1/1/2.jpg']);
      expect(c.paragraphs, ['[插图]', '[插图]']);
    });

    test('没有正文时报错，而不是返回空', () {
      expect(() => parseContent('<html><body>Just a moment</body></html>'), throwsA(isA<Exception>()));
    });
  });

  group('搜索与书架解析', () {
    test('搜索结果去重、兼容绝对链接，不收侧栏链接；作者和下架标记取到', () {
      final r = parseSearch(_searchHtml);
      expect(r.map((e) => e.aid).toList(), [471, 1990]);
      expect(r.first.name, '样本长篇（上）');
      expect(r.map((e) => e.author).toList(), ['样本作者甲', '样本作者乙']);
      expect(r.map((e) => e.delisted).toList(), [true, false]);
      expect(r.first.cover, 'https://img.wenku8.com/image/0/471/471s.jpg');
      expect(WenkuBook.coverOf(3933), 'https://img.wenku8.com/image/3/3933/3933s.jpg');
    });

    test('没有结果时返回空，不把侧栏链接当结果', () {
      expect(parseSearch('<div>对不起，没有搜索到相关的文章！</div><a href="/book/3933.htm">侧栏</a>'), isEmpty);
    });

    test('只有一条结果时源站直接跳到书目页，也能认出来', () {
      final r = parseSearch('<html><title>样本独本 - 轻小说文库</title><span>小说作者：样本作者丙</span><a href="/novel/2/2001/index.htm">小说目录</a></html>');
      expect(r.single.aid, 2001);
      expect(r.single.name, '样本独本');
      expect(r.single.author, '样本作者丙');
    });

    test('jieqi 错误页取出错误原因', () {
      expect(parseSiteError('<title>出现错误</title><div><br>错误原因：对不起，该文章已经在您的书架！<br>'), '对不起，该文章已经在您的书架！');
      expect(parseSiteError('<html>正常页面</html>'), isNull);
    });

    test('书架行按列位解析，空书签不导致错行', () {
      final items = parseShelf(_shelfHtml);
      expect(items.length, 2);
      expect(items.first.entryId, 13346167);
      expect(items.first.aid, 3933);
      expect(items.first.name, '样本小说');
      expect(items.first.author, '样本作者');
      expect(items.first.latest, '插图');
      expect(items.first.bookmark, '');
      expect(items.first.updated, '26-11-02');
      expect(items.last.bookmark, '第二章');
    });

    test('书目页取目录入口的 class', () {
      expect(parseClass('<a href="/novel/3/3933/index.htm">小说目录</a>', 3933), 3);
      expect(() => parseClass('<html></html>', 1), throwsA(isA<Exception>()));
    });
  });

  group('网络层', () {
    late WenkuService api;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      api = WenkuService.instance;
      await api.load();
      await api.logout();
    });

    test('搜索把关键词按 GBK 提交', () async {
      api.adapter = _FakeAdapter((o) => _html(_searchHtml));
      final r = await api.search('刀');
      expect(r.length, 2);
      expect(api.lastRequestUri!.path, '/modules/article/search.php');
      expect(api.lastRequestUri!.query, contains('searchtype=articlename'));
      expect(api.lastRequestUri!.query, contains('%B5%B6'));
    });

    test('Cloudflare 验证页转成「需要网页验证」', () async {
      api.adapter = _FakeAdapter((o) => _html('<html><title>Just a moment...</title></html>', status: 403, headers: {'cf-mitigated': ['challenge']}));
      expect(() => api.search('刀'), throwsA(isA<WenkuBlocked>()));
    });

    test('未登录读正文直接报需要登录，不发请求', () async {
      final fake = _FakeAdapter((o) => _html(''));
      api.adapter = fake;
      await expectLater(api.content(aid: 1, cls: 0, cid: 2), throwsA(isA<WenkuNeedLogin>()));
      expect(fake.requests, isEmpty);
    });

    test('用账号密码登录成功后保存 Cookie', () async {
      api.adapter = _FakeAdapter((o) {
        if (o.uri.path.contains('bookcase')) return _html(_shelfHtml);
        // 登录提交后的页面带「退出」链接才算成功。
        return _html('<html><a href="/logout.php">退出</a></html>', headers: _loginCookies);
      });
      await api.login('someone', 'secret');
      expect(api.loggedIn, isTrue);
      expect(api.username, 'someone');
    });

    test('登录失败时把源站提示原样带出来', () async {
      api.adapter = _FakeAdapter((o) => _html('<html><div id="errormessage">密码不正确</div><form></form></html>'));
      expect(() => api.login('someone', 'bad'), throwsA(predicate((e) => e is Exception && '$e'.contains('密码不正确'))));
      expect(api.loggedIn, isFalse);
    });

    /// 假源站：书架是一组 aid，加入 / 移出会真的改动它，书架页按当前状态生成。
    _FakeAdapter shelfSite(Set<int> shelf, {String? addError}) => _FakeAdapter((o) {
          final q = o.uri.queryParameters;
          if (o.uri.path.endsWith('addbookcase.php')) {
            if (addError != null) return _html('<title>出现错误</title>错误原因：$addError<br>');
            shelf.add(int.parse(q['bid']!));
            return _html('<html>加入书架成功</html>');
          }
          if (o.uri.path.endsWith('bookcase.php')) {
            if (q.containsKey('delid')) shelf.remove(int.parse(q['delid']!) - 10000000);
            final rows = [
              for (final aid in shelf)
                '<tr><td><input type="checkbox" name="checkid[]" value="${10000000 + aid}"></td><td><a href="/book/$aid.htm">样本$aid</a></td><td>作者</td><td>插图</td><td></td><td>26-11-02</td><td>移除</td></tr>',
            ];
            return _html('<table>${rows.join()}</table><a href="/logout.php">退出</a>');
          }
          return _html('<html><a href="/logout.php">退出</a></html>', headers: _loginCookies);
        });

    test('加入书架：带上 bid，回读书架里有这本才算成功', () async {
      final shelf = <int>{};
      final fake = shelfSite(shelf);
      api.adapter = fake;
      await api.login('someone', 'secret');
      final item = await api.addBook(3933);
      expect(item.aid, 3933);
      expect(item.entryId, 10003933);
      expect(fake.requests.any((r) => r.uri.path.endsWith('addbookcase.php') && r.uri.queryParameters['bid'] == '3933'), isTrue);
    });

    test('加入书架失败：书架里没出现，把源站的错误原因带出来', () async {
      api.adapter = shelfSite(<int>{}, addError: '对不起，您的书架已满');
      await api.login('someone', 'secret');
      await expectLater(api.addBook(3933), throwsA(predicate((e) => '$e'.contains('书架已满'))));
    });

    test('移出书架：先查到条目 id 再删，删完回读确认', () async {
      final shelf = {3933, 4455};
      final fake = shelfSite(shelf);
      api.adapter = fake;
      await api.login('someone', 'secret');
      await api.removeBook(3933);
      expect(shelf, {4455});
      expect(fake.requests.any((r) => r.uri.queryParameters['delid'] == '10003933'), isTrue);
      // 本来就不在书架上：不发删除请求，也不报错。
      final before = fake.requests.length;
      await api.removeBook(3933);
      expect(fake.requests.skip(before).any((r) => r.uri.queryParameters.containsKey('delid')), isFalse);
    });
  });
}
