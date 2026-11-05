import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/account.dart';
import '../core/config.dart';
import '../core/installer.dart';
import '../core/models.dart';
import '../core/store.dart';
import '../core/update_service.dart';
import '../ui/format.dart' show formatBytes;
import '../ui/icons.dart';
import 'ios_detail.dart';
import 'ios_discover.dart';
import 'ios_mine.dart';
import 'ios_novel.dart';
import 'ios_reader.dart';
import 'ios_search.dart';
import 'ios_shelf.dart';
import '../core/wenku_web.dart';
import '../ui/motion.dart';
import 'ios_theme.dart';
import 'ios_wenku_novel.dart';

class IosApp extends StatefulWidget {
  const IosApp({super.key});

  @override
  State<IosApp> createState() => _IosAppState();
}

/// 根据「外观设置」和系统外观决定深浅色；切换时整棵树重建，当前页面和导航栈都保留。
class _IosAppState extends State<IosApp> with WidgetsBindingObserver {
  final _prefs = ReaderPrefs.instance;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _prefs.addListener(_apply);
    GlassScope.reduce.value = _prefs.reduceTransparency;
    IosColors.isDark = _wantDark;
    SystemChrome.setSystemUIOverlayStyle(pageChrome);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _prefs.removeListener(_apply);
    super.dispose();
  }

  bool get _wantDark => switch (_prefs.appearance) {
    1 => false,
    2 => true,
    _ => WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.dark,
  };

  @override
  void didChangePlatformBrightness() => _apply();

  void _apply() {
    final dark = _wantDark;
    if (dark == IosColors.isDark || !mounted) return;
    IosColors.isDark = dark;
    SystemChrome.setSystemUIOverlayStyle(pageChrome);
    // 颜色是静态取值，没有依赖关系可通知，所以把所有元素都标脏重建一次。
    void rebuild(Element e) {
      e.markNeedsBuild();
      e.visitChildren(rebuild);
    }

    setState(() {});
    (context as Element).visitChildren(rebuild);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'reader',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      // 根部挂一个 1×1 的隐藏 WebView：轻小说源站拦下 HTTP 客户端时用它取页面。
      builder: (context, child) => GlassScope(
        reduce: GlassScope.reduce,
        child: Stack(
          children: [
            child!,
            Positioned(left: 0, top: 0, child: WenkuWebFetcher.instance.host()),
          ],
        ),
      ),
      home: const IosShell(),
    );
  }
}

class IosShell extends StatefulWidget {
  const IosShell({super.key});

  static final tab = ValueNotifier<int>(0);

  /// 测试里关掉启动时的更新检查。
  static bool autoUpdateCheck = true;

  @override
  State<IosShell> createState() => _IosShellState();
}

class _IosShellState extends State<IosShell> {
  @override
  void initState() {
    super.initState();
    SystemChrome.setSystemUIOverlayStyle(pageChrome);
    if (IosShell.autoUpdateCheck) Future.delayed(const Duration(seconds: 3), _autoCheck);
    // 已登录账号时，打开应用稍后同步一次源站书架和历史（30 分钟内同步过就跳过）。
    if (AccountService.autoSync && AccountService.instance.loggedIn) Future.delayed(const Duration(seconds: 2), AccountService.instance.autoSyncIfDue);
  }

  Future<void> _autoCheck() async {
    final r = await UpdateService.instance.autoCheck();
    if (r != null && mounted) showIosUpdateDialog(context, r);
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
    valueListenable: IosShell.tab,
    // Android 返回键：在发现 / 我的上先回到书架，再退出应用。
    builder: (context, index, _) => PopScope(
      canPop: index == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) IosShell.tab.value = 0;
      },
      child: Scaffold(
        body: Stack(
          children: [
            // 首次进入：内容由下方 7px 淡入归位（只在启动时播一次）；切换标签用 fade-through。
            Positioned.fill(
              child: FadeSlideIn(
                delayMs: 45,
                child: _TabStack(index: index, children: const [IosShelfPage(), IosDiscoverPage(), IosMinePage()]),
              ),
            ),
            // 底部渐隐，让悬浮标签栏下的内容不抢视线。
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 120,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [IosColors.bg.withValues(alpha: 0), IosColors.bg.withValues(alpha: .88)]),
                  ),
                ),
              ),
            ),
            _TabDock(index: index),
          ],
        ),
      ),
    ),
  );
}

/// 三个标签页常驻（保留各自的滚动位置），切换时 fade-through：旧页在前 30% 时间里淡出，
/// 新页在后 70% 淡入，两页不叠在一起；总时长 220ms，不横移。
class _TabStack extends StatefulWidget {
  const _TabStack({required this.index, required this.children});

  final int index;
  final List<Widget> children;

  @override
  State<_TabStack> createState() => _TabStackState();
}

class _TabStackState extends State<_TabStack> with SingleTickerProviderStateMixin {
  late int _current = widget.index;
  int? _previous;
  late final _c = AnimationController(vsync: this, value: 1);

  @override
  void didUpdateWidget(_TabStack old) {
    super.didUpdateWidget(old);
    if (widget.index == _current) return;
    _previous = _current;
    _current = widget.index;
    final d = Motion.of(context, 220);
    if (d == Duration.zero) {
      _previous = null;
      _c.value = 1;
      return;
    }
    _c
      ..duration = d
      ..forward(from: 0).whenCompleteOrCancel(() {
        if (mounted) setState(() => _previous = null);
      });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  static const _out = Interval(0, .3, curve: Motion.exit);
  static const _inCurve = Interval(.3, 1, curve: Motion.ease);

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _c,
    builder: (context, _) => Stack(
      fit: StackFit.expand,
      children: [
        for (var i = 0; i < widget.children.length; i++)
          Offstage(
            offstage: i != _current && i != _previous,
            child: TickerMode(
              enabled: i == _current,
              child: IgnorePointer(
                ignoring: i != _current,
                child: Opacity(
                  opacity: !_c.isAnimating
                      ? 1
                      : i == _current
                      ? _inCurve.transform(_c.value)
                      : 1 - _out.transform(_c.value),
                  child: widget.children[i],
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

class _TabDock extends StatelessWidget {
  const _TabDock({required this.index});

  final int index;

  static const _items = [('book', 'bookFill', '书架'), ('compass', 'compassFill', '发现'), ('person', 'personFill', '我的')];

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Positioned(
      left: 18,
      right: 18,
      bottom: bottom > 0 ? bottom - 6 : 16,
      height: 64,
      child: ListenableBuilder(
        listenable: LibraryStore.instance,
        builder: (context, _) {
          final hasUpdate = LibraryStore.instance.entries.any((e) => e.hasUpdate);
          return Row(
            children: [
              Expanded(
                child: Glass(
                  radius: 32,
                  padding: const EdgeInsets.all(5),
                  child: LayoutBuilder(
                    builder: (context, c) {
                      final w = c.maxWidth / 3;
                      return Stack(
                        children: [
                          AnimatedPositioned(
                            duration: Motion.of(context, 260),
                            curve: Motion.ease,
                            left: w * index,
                            top: 0,
                            bottom: 0,
                            width: w,
                            child: DecoratedBox(
                              decoration: BoxDecoration(color: const Color(0x1A747070), borderRadius: BorderRadius.circular(27)),
                            ),
                          ),
                          Row(
                            children: [
                              for (var i = 0; i < _items.length; i++)
                                Expanded(
                                  child: Pressable(
                                    haptic: true,
                                    pressedScale: .96,
                                    semanticLabel: i == 0 && hasUpdate && index != 0 ? '${_items[i].$3}，有更新' : _items[i].$3,
                                    onTap: () => IosShell.tab.value = i,
                                    child: Column(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Stack(
                                          clipBehavior: Clip.none,
                                          children: [
                                            AppIcon(i == index ? _items[i].$2 : _items[i].$1, size: 23, color: i == index ? IosColors.accent : IosColors.tab, stroke: 1.7),
                                            if (i == 0 && hasUpdate && index != 0)
                                              Positioned(
                                                top: -1,
                                                right: -3,
                                                child: Container(
                                                  width: 8,
                                                  height: 8,
                                                  decoration: BoxDecoration(
                                                    color: IosColors.accent,
                                                    shape: BoxShape.circle,
                                                    border: Border.all(color: IosColors.surface, width: 1.5),
                                                  ),
                                                ),
                                              ),
                                          ],
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          _items[i].$3,
                                          style: TextStyle(
                                            fontSize: 11,
                                            height: 14 / 11,
                                            color: i == index ? IosColors.accent : IosColors.tab,
                                            fontWeight: i == index ? FontWeight.w600 : FontWeight.w500,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Pressable(
                semanticLabel: '搜索',
                onTap: () => Navigator.of(context).push(appRoute((_) => const IosSearchPage())),
                child: Glass(
                  radius: 32,
                  child: SizedBox.square(
                    dimension: 64,
                    child: Center(child: AppIcon('search', size: 25, color: IosColors.ink, stroke: 1.8)),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/* ───────── 导航 ───────── */

ComicBrief briefOfEntry(ShelfEntry e) => ComicBrief(name: e.name, pathWord: e.id, cover: e.cover, authors: [e.author]);

Future<void> iosOpenDetail(BuildContext context, ComicBrief comic) => Navigator.of(context).push(appRoute((_) => IosDetailPage(comic: comic)));

Future<void> iosOpenReader(BuildContext context, {required ComicBrief comic, required String group, required String chapterUuid, int initialPage = 0}) =>
    Navigator.of(context).push(readerRoute((_) => IosReaderPage(comic: comic, group: group, chapterUuid: chapterUuid, initialPage: initialPage)));

Future<void> iosOpenNovel(BuildContext context) => Navigator.of(context).push(readerRoute((_) => const IosNovelPage()));

/// 源站的轻小说（书架 id 是 `wenku-<aid>`）。内置示例小说仍走 [iosOpenNovel]。
Future<void> iosOpenWenkuNovel(BuildContext context, {required int aid, String name = ''}) => Navigator.of(context).push(readerRoute((_) => IosWenkuNovelPage(aid: aid, name: name)));

/// 继续阅读：小说进阅读器，漫画有进度进阅读器，否则进详情。
Future<void> iosContinue(BuildContext context, ShelfEntry e) {
  if (e.kind == ShelfKind.novel) {
    final aid = wenkuAidOf(e.id);
    return aid == null ? iosOpenNovel(context) : iosOpenWenkuNovel(context, aid: aid, name: e.name);
  }
  if (e.chapterUuid == null) return iosOpenDetail(context, briefOfEntry(e));
  return iosOpenReader(context, comic: briefOfEntry(e), group: e.group ?? 'default', chapterUuid: e.chapterUuid!, initialPage: e.page);
}

/* ───────── 更新 ───────── */

/// 新版本弹窗：公告取 GitHub Release 的正文，Android 可以在应用内下载并直接安装。
Future<void> showIosUpdateDialog(BuildContext context, UpdateResult r) {
  final release = r.release!;
  final meta = [
    '当前 v${r.current}',
    if (release.packageSize != null) '安装包 ${formatBytes(release.packageSize!)}',
    if (release.publishedAt != null) '${release.publishedAt!.month}月${release.publishedAt!.day}日发布',
  ].join(' · ');
  final notes = plainNotes(release.notes);
  return showAppSheet<void>(context, (_) => _UpdateSheet(release: release, meta: meta, notes: notes.isEmpty ? release.title : notes));
}

class _UpdateSheet extends StatefulWidget {
  const _UpdateSheet({required this.release, required this.meta, required this.notes});

  final AppRelease release;
  final String meta;
  final String notes;

  @override
  State<_UpdateSheet> createState() => _UpdateSheetState();
}

class _UpdateSheetState extends State<_UpdateSheet> {
  double? _progress;
  bool _downloading = false;
  String? _error;

  /// 只有 Android 且真有安装包时才能应用内下载；其余走浏览器。
  bool get _canInstall => defaultTargetPlatform == TargetPlatform.android && widget.release.packageUrl != null;

  Future<void> _download() async {
    setState(() {
      _downloading = true;
      _progress = null;
      _error = null;
    });
    try {
      final file = await UpdateService.instance.download(widget.release, onProgress: (p) {
        if (mounted) setState(() => _progress = p);
      });
      final opened = await AppInstaller.install(file.path);
      if (!mounted) return;
      setState(() => _downloading = false);
      if (!opened) showIosToast(context, '请允许「安装未知应用」后再点一次下载');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _error = '$e';
      });
    }
  }

  void _openBrowser() {
    Navigator.pop(context);
    launchUrl(Uri.parse(widget.release.downloadUrl), mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.fromLTRB(14, 0, 14, MediaQuery.paddingOf(context).bottom + 10),
        child: Glass(
          radius: 30,
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 5,
                  margin: const EdgeInsets.only(bottom: 14),
                  decoration: BoxDecoration(color: const Color(0x33000000), borderRadius: BorderRadius.circular(3)),
                ),
              ),
              Text('发现新版本 v${widget.release.version}', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w700, color: IosColors.ink)),
              const SizedBox(height: 4),
              Text(widget.meta, style: TextStyle(fontSize: 12, color: IosColors.muted)),
              const SizedBox(height: 14),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 240),
                child: SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  child: Text(widget.notes, style: TextStyle(fontSize: 14, height: 1.6, color: IosColors.ink)),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: TextStyle(fontSize: 13, color: IosColors.accent)),
                const SizedBox(height: 6),
                Center(
                  child: TextAction(
                    label: '打开 Releases 手动下载',
                    color: IosColors.accent,
                    onTap: () async {
                      Navigator.pop(context);
                      await launchUrl(Uri.parse(AppConfig.githubReleasesPage), mode: LaunchMode.externalApplication);
                    },
                  ),
                ),
              ],
              const SizedBox(height: 18),
              if (_downloading) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: _progress,
                    minHeight: 5,
                    backgroundColor: IosColors.faint,
                    valueColor: AlwaysStoppedAnimation(IosColors.accent),
                  ),
                ),
                const SizedBox(height: 8),
                Center(
                  child: Text(
                    _progress == null ? '正在下载…' : '正在下载 ${(_progress! * 100).round()}%',
                    style: TextStyle(fontSize: 13, color: IosColors.muted),
                  ),
                ),
              ] else
                Row(
                  children: [
                    Expanded(
                      child: TextAction(
                        label: '跳过此版本',
                        color: IosColors.muted,
                        onTap: () {
                          ReaderPrefs.instance.skipVersion = widget.release.version;
                          Navigator.pop(context);
                        },
                      ),
                    ),
                    const SizedBox(width: 10),
                    Pressable(
                      onTap: _canInstall ? _download : _openBrowser,
                      child: Container(
                        height: 46,
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        decoration: BoxDecoration(color: IosColors.accent, borderRadius: BorderRadius.circular(23)),
                        child: Center(
                          child: Text(
                            _canInstall ? '下载并安装' : '下载',
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: IosColors.onAccent),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              if (_canInstall && !_downloading)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Center(
                    child: TextAction(label: '用浏览器下载', color: IosColors.muted, onTap: _openBrowser),
                  ),
                ),
            ],
          ),
        ),
      );
}

/// 「我的」里的手动检查。检查失败时可以直接打开 Releases 页手动下载。
Future<UpdateResult> iosManualUpdateCheck(BuildContext context) async {
  final r = await UpdateService.instance.check();
  if (!context.mounted) return r;
  if (r.status == UpdateStatus.available) {
    await showIosUpdateDialog(context, r);
  } else if (r.status == UpdateStatus.failed) {
    final open = await showCupertinoDialog<bool>(
      context: context,
      builder: (dialog) => CupertinoAlertDialog(
        title: const Text('检查更新失败'),
        content: Text('${r.message ?? '无法连接更新服务'}\n\n可以打开项目 Releases 页手动下载。'),
        actions: [
          CupertinoDialogAction(onPressed: () => Navigator.pop(dialog, false), child: const Text('稍后')),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('打开 Releases'),
          ),
        ],
      ),
    );
    if (open == true) await launchUrl(Uri.parse(AppConfig.githubReleasesPage), mode: LaunchMode.externalApplication);
  } else {
    showIosToast(context, switch (r.status) {
      UpdateStatus.upToDate => r.message ?? '已是最新版本 v${r.current}',
      UpdateStatus.noRelease => '仓库还没有发布版本',
      _ => r.message ?? '检查更新失败',
    });
  }
  return r;
}
