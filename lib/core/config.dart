/// 数据源与网络配置。
class AppConfig {
  AppConfig._();

  /// 全链路请求头。这套（移动端 WebView）是 `mapi.*` 系列唯一认的；
  /// 实测删掉 `webp`、`version`、`platform` 任一项都会被直接返回 HTML。
  static const apiHeaders = <String, String>{
    'Accept': 'application/json',
    'platform': '3',
    'version': '2025.06.01',
    'webp': '1',
    'X-Requested-With': 'com.manga2020.app',
    'User-Agent': 'Mozilla/5.0 (Linux; Android 15; 23113RKC6C Build/AQ3A.240812.002; wv) '
        'AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 '
        'Chrome/131.0.6778.200 Mobile Safari/537.36',
  };

  /// 线路表。同一线路里的域名互为备份，共用上面这套请求头。
  ///
  /// 实测（2026-11-05，国内直连）：`hotmangas` 三台解析到同一个越南 IP
  /// `171.244.199.146`，不挂代理 40/40 通、中位 269ms；`club` 与 `manga2026`
  /// 走 Cloudflare，国内直连基本不通，只在代理环境下可用。
  static const routes = <ApiRoute>[
    ApiRoute(
      id: 'hotmangas',
      name: '国内直连',
      note: '不挂代理可用 · 实测最快',
      direct: true,
      hosts: [
        'https://mapi.hotmangasg.com',
        'https://mapi.hotmangasd.com',
        'https://mapi.hotmangasf.com',
      ],
    ),
    ApiRoute(
      id: 'club',
      name: '备用线路',
      note: 'Cloudflare · 国内一般需要代理',
      hosts: [
        'https://mapi.elfgjfghkk.club',
        'https://mapi.fgjfghkkcenter.club',
        'https://mapi.fgjfghkk.club',
      ],
    ),
    ApiRoute(
      id: 'manga2026',
      name: '旧线路',
      note: 'Cloudflare · 国内一般需要代理',
      hosts: ['https://www.manga2026.xyz'],
    ),
  ];

  /// 网页端主机：账号登录走这里（App 端登录需要额外的加密值，没有打通）。
  static const webHost = 'https://www.copy4000.com';

  static const imageHeaders = <String, String>{'User-Agent': 'COPY/3.1.0'};

  /// 编译期默认代理，例如 MuMu 内访问宿主机 Clash：
  /// `flutter run --dart-define=PROXY=10.0.2.2:7897`
  static const defaultProxy = String.fromEnvironment('PROXY');

  /// 应用更新从这个仓库的 GitHub Releases 获取。
  static const githubRepo = 'wymdxiao/reader';
  static const githubPage = 'https://github.com/$githubRepo';

  /// Releases 列表页：更新检测或安装失败时，让用户直接去这里手动下载。
  static const githubReleasesPage = '$githubPage/releases/latest';

  static const releasesApi = 'https://api.github.com/repos/$githubRepo/releases/latest';

  /// 更新检测与下载的镜像前缀，按实测顺序排列（2026-11-05 国内直连实测）：
  /// - 直连 `api.github.com`：656ms，可用
  /// - `gh-proxy.com`：1100ms，可用（接口和安装包都通）
  /// - `ghproxy.net`：接口 403，但安装包能下，所以只放进下载兜底
  ///
  /// 其余测过的（`ghfast.top`、`hub.gitmirror.com`、`gh.llkk.cc`、`ghproxy.cc`、
  /// `github.moeyy.xyz`）当时都超时或证书错误，不列进来免得拖慢检测。
  static const githubApiMirrors = <String>[
    '', // 直连
    'https://gh-proxy.com/',
  ];

  /// 只需要下载安装包、不需要读接口的镜像。
  static const githubDownloadMirrors = <String>[
    '',
    'https://gh-proxy.com/',
    'https://ghproxy.net/',
  ];

  /// 题材筛选（`/api/v3/comics?theme=`）。名称与 path_word 取自 `filter/book/tags`，漫画列表同样适用。
  static const themes = <(String, String)>[
    ('愛情', 'aiqing'), ('校園', 'xiaoyuan'), ('奇幻', 'qihuan'), ('青春', 'qingchun'), ('後宮', 'hougong'),
    ('戰鬥', 'zhandou'), ('歡樂向', 'huanlexiang'), ('冒險', 'maoxian'), ('懸疑', 'xuanyi'), ('科幻', 'kehuan'),
    ('穿越', 'chuanyue'), ('青梅竹馬', 'qingmeizhuma'), ('人外', 'renwai'), ('魔法', 'mofa'), ('百合', 'baihe'),
  ];
}

/// 一条线路：一组互为备份的域名，共用同一套请求头。
class ApiRoute {
  const ApiRoute({required this.id, required this.name, required this.hosts, this.note = '', this.direct = false});

  final String id;
  final String name;
  final String note;

  /// 实测在国内不挂代理可用。只用于界面提示，不参与选路。
  final bool direct;

  /// 完整基址，例如 `https://mapi.hotmangasg.com`。
  final List<String> hosts;

  String get shortName => hosts.first.replaceFirst('https://', '');
}
