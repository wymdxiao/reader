package com.wymdxiao.reader

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/// 应用内下载更新后直接调用系统安装器；没有「安装未知应用」权限时把用户送到授权页。
class MainActivity : FlutterActivity() {
    private val channel = "pmx/installer"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channel).setMethodCallHandler { call, result ->
            when (call.method) {
                "install" -> {
                    val path = call.argument<String>("path")
                    if (path == null) {
                        result.error("bad_args", "缺少安装包路径", null)
                        return@setMethodCallHandler
                    }
                    try {
                        result.success(install(File(path)))
                    } catch (e: Exception) {
                        result.error("install_failed", e.message, null)
                    }
                }
                "canInstall" -> result.success(canRequestInstall())
                else -> result.notImplemented()
            }
        }
    }

    private fun canRequestInstall(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) packageManager.canRequestPackageInstalls() else true

    private fun install(file: File): Boolean {
        if (!file.exists()) return false
        if (!canRequestInstall()) {
            // 跳转到「安装未知应用」授权页，用户回来后可以再点一次安装。
            val intent = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES)
                .setData(Uri.parse("package:$packageName"))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
            return false
        }
        val uri: Uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, "application/vnd.android.package-archive")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        startActivity(intent)
        return true
    }
}
