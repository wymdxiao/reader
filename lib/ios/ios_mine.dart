import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/account.dart';
import '../core/api.dart';
import '../core/config.dart';
import '../core/routes.dart';
import '../core/store.dart';
import '../core/update_service.dart';
import '../ui/motion.dart';
import '../ui/format.dart' show formatBytes;
import 'ios_account.dart';
import 'ios_app.dart';
import 'ios_settings.dart';
import 'ios_source.dart';
import 'ios_theme.dart';

/// 修改网络代理。默认「跟随系统」：系统 VPN 类代理会自动生效；需要 HTTP 代理时再填 host:port。
Future<void> iosEditProxy(BuildContext context) async {
  final prefs = ReaderPrefs.instance;
  final v = await showIosPrompt(
    context,
    title: '网络代理',
    message: '留空即跟随系统（VPN 类代理自动生效）。需要 HTTP 代理时填写 host:port，重启应用后生效。',
    initial: prefs.proxy,
    placeholder: '例如 192.168.1.10:7890',
    confirm: '保存',
  );
  if (v == null) return;
  prefs.proxy = v;
  if (context.mounted) showIosToast(context, '已保存，重启应用后生效');
}

class IosMinePage extends StatefulWidget {
  const IosMinePage({super.key});

  @override
  State<IosMinePage> createState() => _IosMinePageState();
}

class _IosMinePageState extends State<IosMinePage> {
  final _prefs = ReaderPrefs.instance;
  final _store = LibraryStore.instance;
  final _account = AccountService.instance;
  String? _ping;
  bool _pingOk = false;
  bool _pinging = false;
  DateTime? _pingedAt;
  int? _cacheBytes;
  String _version = '';
  bool _checking = false;
  UpdateResult? _update;

  @override
  void initState() {
    super.initState();
    _prefs.addListener(_changed);
    _store.addListener(_changed);
    _account.addListener(_changed);
    IosShell.tab.addListener(_onTab);
    UpdateService.instance.currentVersion().then((v) {
      if (mounted) setState(() => _version = v);
    });
  }

  @override
  void dispose() {
    _prefs.removeListener(_changed);
    _store.removeListener(_changed);
    _account.removeListener(_changed);
    IosShell.tab.removeListener(_onTab);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _onTab() {
    if (IosShell.tab.value != 2) return;
    if (_pingedAt == null || DateTime.now().difference(_pingedAt!) > const Duration(minutes: 1)) _testSource();
    _measureCache();
  }

  Future<void> _testSource() async {
    setState(() => _pinging = true);
    try {
      final d = await MangaApi.instance.ping();
      _ping = '正常 · ${d.inMilliseconds}ms';
      _pingOk = true;
    } catch (_) {
      _ping = '连接失败';
      _pingOk = false;
    }
    _pingedAt = DateTime.now();
    if (mounted) setState(() => _pinging = false);
  }

  Future<void> _measureCache() async {
    var total = 0;
    try {
      final dir = Directory('${(await getTemporaryDirectory()).path}/${DefaultCacheManager.key}');
      if (await dir.exists()) {
        await for (final f in dir.list(recursive: true, followLinks: false)) {
          if (f is File) total += await f.length();
        }
      }
    } catch (_) {}
    if (mounted) setState(() => _cacheBytes = total);
  }

  Future<void> _cacheMenu() async {
    final i = await showIosChoices(context, title: '图片缓存 ${_cacheBytes == null ? '' : formatBytes(_cacheBytes!)}', options: const ['清除图片缓存'], destructiveIndex: 0);
    if (i != 0) return;
    await DefaultCacheManager().emptyCache();
    imageCache.clear();
    await _measureCache();
    if (mounted) showIosToast(context, '图片缓存已清除');
  }

  Future<void> _clearHistory() async {
    final ok = await showCupertinoDialog<bool>(
      context: context,
      builder: (dialog) => CupertinoAlertDialog(
        title: const Text('清除阅读记录？'),
        content: const Text('会清掉每部作品读到哪一页和已读标记。书架上的作品和追更状态会保留。'),
        actions: [
          CupertinoDialogAction(onPressed: () => Navigator.pop(dialog, false), child: const Text('取消')),
          CupertinoDialogAction(isDestructiveAction: true, onPressed: () => Navigator.pop(dialog, true), child: const Text('清除')),
        ],
      ),
    );
    if (ok == true) _store.clearHistory();
  }

  void _open(Widget page) => Navigator.of(context).push(appRoute<void>((_) => page));

  Future<void> _checkUpdate() async {
    setState(() => _checking = true);
    final r = await iosManualUpdateCheck(context);
    if (mounted) {
      setState(() {
        _checking = false;
        _update = r;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const BouncingScrollPhysics(),
      padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top, bottom: 130),
      children: [
        const LargeTitle('我的'),
        InsetGroup(title: '偏好设置', children: [
          IosRow(icon: 'sun', title: '外观设置', subtitle: '深色模式、透明度', onTap: () => _open(const IosAppearancePage())),
          IosRow(icon: 'book', title: '阅读设置', subtitle: '翻页方式、画质、小说排版', onTap: () => _open(const IosReadingSettingsPage())),
          IosRow(
            icon: 'person',
            title: '账号同步',
            subtitle: _account.loggedIn ? '已登录 ${_account.displayName}' : '登录拷贝漫画，同步书架和历史',
            onTap: () => _open(const IosAccountPage()),
          ),
        ]),
        InsetGroup(title: '网络', children: [
          IosRow(
            icon: 'globe',
            title: '数据源',
            subtitle: '${RouteSelector.instance.activeRouteName} · ${MangaApi.instance.activeHost}',
            valueWidget: _pinging
                ? const CupertinoActivityIndicator()
                : Row(mainAxisSize: MainAxisSize.min, children: [
                    if (_ping != null) ...[
                      Container(width: 7, height: 7, decoration: BoxDecoration(color: _pingOk ? const Color(0xFF3E8E5A) : IosColors.accent, shape: BoxShape.circle)),
                      const SizedBox(width: 6),
                    ],
                    Text(_ping ?? '点按测试', style: TextStyle(fontSize: 15, color: _ping != null && !_pingOk ? IosColors.accent : IosColors.muted)),
                  ]),
            onTap: () => _open(const IosSourcePage()),
          ),
          IosRow(icon: 'route', title: '网络代理', value: _prefs.proxy.isEmpty ? '跟随系统' : _prefs.proxy, onTap: () => iosEditProxy(context)),
        ]),
        InsetGroup(title: '存储', children: [
          IosRow(icon: 'database', title: '图片缓存', subtitle: '只保存看过的页面', value: _cacheBytes == null ? '—' : formatBytes(_cacheBytes!), onTap: _cacheMenu),
          IosRow(
            icon: 'history',
            title: '阅读记录',
            subtitle: '书架 ${_store.entries.length} 部 · 已读 ${_store.readChapterCount} 话',
            valueWidget: Text('清除', style: TextStyle(fontSize: 15, color: IosColors.accent)),
            chevron: false,
            onTap: _clearHistory,
          ),
        ]),
        InsetGroup(title: '关于', footer: 'reader只是阅读器：不内置账号，不绕过付费与会员限制。作品实时来自源站，版权归原作者和权利人所有。', children: [
          IosRow(
            icon: 'download',
            title: '检查更新',
            subtitle: '当前 v$_version · GitHub Releases',
            valueWidget: _checking
                ? const CupertinoActivityIndicator()
                : Text(
                    switch (_update?.status) {
                      UpdateStatus.available => 'v${_update!.release!.version}',
                      UpdateStatus.upToDate => '已是最新',
                      UpdateStatus.noRelease => '暂无发布',
                      UpdateStatus.failed => '检查失败',
                      null => '',
                    },
                    style: TextStyle(fontSize: 15, color: _update?.status == UpdateStatus.available || _update?.status == UpdateStatus.failed ? IosColors.accent : IosColors.muted),
                  ),
            onTap: _checking ? null : _checkUpdate,
          ),
          IosRow(
            title: '启动时自动检查',
            subtitle: '每次打开应用检查一次，可随时关闭',
            chevron: false,
            valueWidget: CupertinoSwitch(value: _prefs.autoUpdate, activeTrackColor: IosColors.accent, onChanged: (v) => setState(() => _prefs.autoUpdate = v)),
            onTap: () => setState(() => _prefs.autoUpdate = !_prefs.autoUpdate),
          ),
          IosRow(icon: 'github', title: '项目主页', subtitle: AppConfig.githubPage.replaceFirst('https://', ''), onTap: () => launchUrl(Uri.parse(AppConfig.githubPage), mode: LaunchMode.externalApplication)),
        ]),
      ],
    );
  }
}
