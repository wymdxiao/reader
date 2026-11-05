import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reader/core/models.dart';

/// fixtures 为真实接口的原始响应；detail / chapters / chapter 三个文件只含 results 部分。
Map<String, dynamic> fixture(String name, {bool envelope = true}) {
  final j = jsonDecode(File('test/fixtures/$name').readAsStringSync()) as Map<String, dynamic>;
  return envelope ? j['results'] as Map<String, dynamic> : j;
}

void main() {
  test('漫画列表', () {
    final page = PageResult.parse(fixture('comics_list.json'), ComicBrief.fromJson);
    expect(page.total, 56220);
    expect(page.list, hasLength(5));
    expect(page.hasMore, isTrue);
    final c = page.list.first;
    expect(c.pathWord, 'xilingjiang');
    expect(c.cover, startsWith('https://'));
    expect(c.authors, isNotEmpty);
  });

  test('排行榜', () {
    final page = PageResult.parse(fixture('ranks.json'), RankItem.fromJson);
    expect(page.total, 198);
    expect(page.list.first.sort, 1);
    expect(page.list.first.comic.pathWord, 'naoodngxueshenghui');
  });

  test('搜索', () {
    final page = PageResult.parse(fixture('search.json'), ComicBrief.fromJson);
    expect(page.total, 34);
    expect(page.list.first.pathWord, 'crowshaizeiban');
  });

  test('详情：groups 是字典，status/region 是对象', () {
    final d = ComicDetail.fromJson(fixture('detail.json', envelope: false));
    expect(d.comic.pathWord, 'youdiannianrendejiaxiaozinvyou');
    expect(d.groups, hasLength(1));
    expect(d.groups.first.pathWord, 'default');
    expect(d.groups.first.count, 16);
    expect(d.status, isNotEmpty);
    expect(d.region, isNotEmpty);
    expect(d.themes, isNotEmpty);
    expect(d.isLock, isFalse);
  });

  test('章节列表：prev/next 可直接翻话', () {
    final page = PageResult.parse(fixture('chapters.json', envelope: false), Chapter.fromJson);
    expect(page.total, 16);
    final first = page.list.first;
    expect(first.prev, isNull);
    expect(first.next, page.list[1].uuid);
    expect(first.size, 3);
  });

  test('章节正文：contents 顺序即阅读顺序', () {
    final c = ChapterContent.fromJson(fixture('chapter.json', envelope: false));
    expect(c.images, hasLength(3));
    expect(c.images.every((u) => u.startsWith('https://')), isTrue);
    expect(c.chapter.next, isNotNull);
    expect(c.isLock, isFalse);
  });
}
