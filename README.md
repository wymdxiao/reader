# reader / 漫画阅读器

一个 Flutter 写的漫画与轻小说阅读器，Android 与 iOS 共用同一套界面。

## 功能

- **书架**：继续阅读、更新提醒（新 N 话），可按连载状态筛选、按阅读或更新时间排序
- **发现**：题材筛选、今日更新、日 / 周 / 月 / 总排行
- **搜索**：作品名和作者一起搜，关键词高亮；可切换搜索范围，也能搜轻小说
- **作品详情**：多分组章节、按百话分段浏览、一键定位到在读那一话
- **漫画阅读器**：单页或条漫、左右翻页方向、双击缩放、省流画质、页面亮度，话末自动接上下一话
- **轻小说**：接入 Wenku8，支持登录、书架同步、搜索、正文带插图阅读；左右翻页或整章滚动、分卷目录、书签与阅读进度
- **线路自动选择**：内置多条源站线路，启动时测速选最快的一条，断开自动换线；可手动固定线路或填自建中转地址
- **应用内更新**：启动自动检查**本仓库**的 Releases（可关闭），支持镜像加速、应用内下载并安装；失败时可直接打开 Releases 页

## 下载

在本仓库的 [Releases](https://github.com/wymdxiao/reader/releases) 下载：

- **Android**：`reader-vX.Y.Z.apk` 通用包（arm / arm64 / x64 都能装），需要 Android 7.0 及以上
- **iOS**：`reader-vX.Y.Z-unsigned.ipa`，需要 iOS 26 及以上；安装包未签名，用 Sideloadly、AltStore 等工具以自己的 Apple ID 签名后安装

## 构建

需要 Flutter 3.47 及以上。

```bash
flutter pub get
flutter run
flutter test
flutter build apk --release                    # 通用包
flutter build apk --release --split-per-abi    # 按架构拆分
```

Android 正式版签名读取 `android/key.properties`，这个文件不在仓库里；没有它时会用 debug 签名打包。

iOS 安装包由 GitHub Actions 在 macOS 上构建（`.github/workflows/ios-ipa.yml`），产出未签名的 `reader-vX.Y.Z-unsigned.ipa`，也可以在本机用 `flutter build ios --release --no-codesign` 构建。

发布新版本：先修改 `pubspec.yaml` 的 `version`，再新建 tag 为 `vX.Y.Z` 的 Release 并附上 APK；工作流会自动把 IPA 附到同一个 Release，应用会据此提示更新。

## 应用标识

| 项 | 值 |
|---|---|
| iOS Bundle Identifier | `com.wymdxiao.reader` |
| Android applicationId | `com.wymdxiao.reader` |
| 显示名称 | `reader` |
| 版本 | 见 `pubspec.yaml` |

## 声明

本项目只是一个阅读器：不内置任何账号，不绕过付费或会员限制，也不提供批量下载。作品内容实时来自第三方源站，版权归原作者和权利人所有。
