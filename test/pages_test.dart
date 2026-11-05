import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:reader/core/account.dart';
import 'package:reader/core/shelf_sync.dart';
import 'package:reader/core/store.dart';
import 'package:reader/core/update_service.dart';
import 'package:reader/ios/ios_account.dart';
import 'package:reader/ios/ios_app.dart';
import 'package:reader/ios/ios_mine.dart';
import 'package:reader/ios/ios_novel.dart';
import 'package:reader/ios/ios_shelf.dart';
import 'package:reader/ios/ios_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 两端用同一套界面，每个用例在 iOS 和 Android 上各跑一遍。
void uiTest(String name, WidgetTesterCallback body) =>
    testWidgets(name, body, variant: const TargetPlatformVariant({TargetPlatform.iOS, TargetPlatform.android}));

/// 界面：按 393×852 手机尺寸渲染，检查布局溢出与关键交互。
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(appName: 'reader', packageName: 'com.wymdxiao.reader', version: '0.3.0', buildNumber: '3', buildSignature: '');
    await initStores();
    await AccountService.instance.load();
    AccountService.autoSync = false;
    ShelfSync.enabled = false;
    IosShell.autoUpdateCheck = false;
    IosShell.tab.value = 0;
    GlassScope.reduce.value = false;
    IosColors.isDark = false;
  });

  Future<void> pump(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3;
    tester.view.padding = const FakeViewPadding(top: 177, bottom: 102);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      builder: (context, c) => GlassScope(reduce: GlassScope.reduce, child: c!),
      home: Scaffold(body: child),
    ));
    await tester.pump(const Duration(milliseconds: 100));
  }

  ShelfEntry manga(String id, {int latest = 10, int seen = 10, bool started = false, String status = '連載中'}) => ShelfEntry(
        id: id,
        kind: ShelfKind.manga,
        name: '作品$id',
        cover: '',
        author: '作者',
        status: status,
        latestChapter: '第$latest话',
        latestUpdated: '2026-11-03',
        latestCount: latest,
        seenCount: seen,
        chapterUuid: started ? 'u$id' : null,
        chapterName: started ? '第245话' : null,
        page: 2,
        pageCount: 16,
        progress: started ? .19 : 0,
      );

  uiTest('书架：首次使用', (tester) async {
    await pump(tester, const IosShelfPage());
    expect(find.text('好故事，从第一本开始'), findsOneWidget);
    await tester.tap(find.text('去发现'));
    expect(IosShell.tab.value, 1);
  });

  uiTest('书架：最近在读、有更新、筛选', (tester) async {
    final store = LibraryStore.instance;
    store.put(manga('a', started: true));
    store.put(manga('b', latest: 12, seen: 10));
    store.put(manga('c', status: '已完結'));
    await pump(tester, const IosShelfPage());

    expect(find.text('最近在读'), findsOneWidget);
    expect(find.text('第245话  第 3 / 16 页'), findsOneWidget);
    expect(find.text('新 2 话'), findsOneWidget);
    expect(find.text('我的藏书'), findsOneWidget);

    await tester.tap(find.text('已完结'));
    await tester.pump();
    expect(find.text('作品c'), findsWidgets);
    expect(find.text('作品b'), findsNothing);
  });

  uiTest('标签栏：三个标签 + 搜索', (tester) async {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const IosApp());
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('书架'), findsWidgets);
    expect(find.bySemanticsLabel('搜索'), findsWidgets);
    await tester.tap(find.text('我的').last);
    await tester.pump(const Duration(milliseconds: 400));
    expect(IosShell.tab.value, 2);
  });

  uiTest('返回键：在发现 / 我的上先回到书架', (tester) async {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const IosApp());
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('发现').last);
    await tester.pump(const Duration(milliseconds: 400));
    expect(IosShell.tab.value, 1);

    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 400));
    expect(IosShell.tab.value, 0);
  });

  uiTest('更新弹窗：本平台的安装包、更新内容、跳过此版本', (tester) async {
    final ios = defaultTargetPlatform == TargetPlatform.iOS;
    final r = UpdateService.resolve(200, {
      'tag_name': 'v0.4.0',
      'name': 'v0.4.0',
      'body': '## 新增\n- 两端界面统一\n- **省流**画质',
      'html_url': 'https://github.com/wymdxiao/reader/releases/tag/v0.4.0',
      'published_at': '2026-11-05T08:00:00Z',
      'assets': [
        {'name': 'reader-v0.4.0.apk', 'size': 19293798, 'browser_download_url': 'https://example.com/a.apk'},
        {'name': 'reader-v0.4.0-unsigned.ipa', 'size': 7757782, 'browser_download_url': 'https://example.com/a.ipa'},
      ],
    }, '0.3.0', ext: ios ? '.ipa' : '.apk', requirePackage: ios);
    expect(r.release!.packageUrl, ios ? 'https://example.com/a.ipa' : 'https://example.com/a.apk');

    await pump(tester, Builder(builder: (context) => CupertinoButton(onPressed: () => showIosUpdateDialog(context, r), child: const Text('open'))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('发现新版本 v0.4.0'), findsOneWidget);
    expect(find.textContaining(ios ? '安装包 7.4 MB' : '安装包 18.4 MB'), findsOneWidget);
    expect(find.textContaining('• 省流画质'), findsOneWidget);

    await tester.tap(find.text('跳过此版本'));
    await tester.pumpAndSettle();
    expect(ReaderPrefs.instance.skipVersion, '0.4.0');
    expect(find.text('发现新版本 v0.4.0'), findsNothing);
  });

  uiTest('我的：外观、阅读两个设置入口，版本号', (tester) async {
    await pump(tester, const IosMinePage());
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('外观设置'), findsOneWidget);
    expect(find.text('阅读设置'), findsOneWidget);
    expect(find.text('漫画翻页方向'), findsNothing);
    expect(find.text('跟随系统'), findsOneWidget);
    await tester.scrollUntilVisible(find.textContaining('当前 v0.3.0'), 200);
    expect(find.textContaining('当前 v0.3.0'), findsOneWidget);

    await tester.scrollUntilVisible(find.text('阅读设置'), -200);
    await tester.tap(find.text('阅读设置'));
    await tester.pumpAndSettle();
    expect(find.text('翻页方向'), findsOneWidget);
    expect(find.text('纸白 · 19 磅'), findsOneWidget);
    await tester.tap(find.text('阅读方式'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('条漫').last);
    await tester.pumpAndSettle();
    expect(ReaderPrefs.instance.mangaScroll, isTrue);
  });

  uiTest('账号同步：未登录显示登录表单，填好账号密码才能登录', (tester) async {
    await pump(tester, const IosAccountPage());
    expect(find.text('拷贝漫画账号'), findsOneWidget);
    expect(find.text('登录并同步'), findsOneWidget);
    expect(find.textContaining('不保存在本机'), findsOneWidget);
    final fields = find.byType(CupertinoTextField);
    expect(fields, findsNWidgets(2));
    expect(tester.widget<CupertinoTextField>(fields.last).obscureText, isTrue);

    // 没填密码时按钮不可用。
    await tester.enterText(fields.first, 'reader');
    await tester.pump();
    await tester.tap(find.text('登录并同步'));
    await tester.pump();
    expect(AccountService.instance.busy, isFalse);
    expect(AccountService.instance.loggedIn, isFalse);
  });

  uiTest('外观设置：深色模式整体切换，减少透明度', (tester) async {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const IosApp());
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('我的').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('外观设置'));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(CupertinoSwitch));
    await tester.pumpAndSettle();
    expect(ReaderPrefs.instance.reduceTransparency, isTrue);
    expect(GlassScope.reduce.value, isTrue);

    await tester.tap(find.text('深色模式'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('深色').last);
    await tester.pumpAndSettle();
    expect(ReaderPrefs.instance.appearance, 2);
    expect(IosColors.isDark, isTrue);
    // 切换后当前页面还在，背景已经换成深色。
    expect(find.text('跟随系统'), findsOneWidget);
    expect(tester.widget<Scaffold>(find.byType(Scaffold).last).backgroundColor, IosColors.dBg);

    await tester.tap(find.text('浅色'));
    await tester.pumpAndSettle();
    expect(IosColors.isDark, isFalse);
  });

  uiTest('小说：阅读外观 → 字体与排版', (tester) async {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      builder: (context, c) => GlassScope(reduce: GlassScope.reduce, child: c!),
      home: const IosNovelPage(),
    ));
    await tester.pumpAndSettle();
    expect(find.text('雨停之前'), findsWidgets);
    expect(find.text('1  /  1'), findsNothing);

    await tester.tap(find.text('阅读设置'));
    await tester.pumpAndSettle();
    expect(find.text('阅读外观'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('暖纸'));
    await tester.pumpAndSettle();
    expect(ReaderPrefs.instance.theme, 1);

    expect(find.byType(CupertinoSwitch), findsNothing);

    await tester.tap(find.text('字体与排版'));
    await tester.pumpAndSettle();
    expect(find.text('阅读字体'), findsOneWidget);
    await tester.tap(find.text('黑体'));
    await tester.pumpAndSettle();
    expect(ReaderPrefs.instance.font, 1);
    await tester.tap(find.text('恢复默认排版'));
    await tester.pumpAndSettle();
    expect(ReaderPrefs.instance.font, 0);
    expect(ReaderPrefs.instance.lineHeight, 1.85);
  });
}
