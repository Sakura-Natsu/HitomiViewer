package com.example.hitomi_reader

import android.Manifest
import android.content.ContentValues
import android.content.Context
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.os.BatteryManager
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 阅读器用：屏幕常亮、电量显示、保存图片（见 lib/services/device.dart）
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "hitomi_reader/device")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "keepScreenOn" -> {
                        val flag = WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
                        if (call.arguments == true) window.addFlags(flag) else window.clearFlags(flag)
                        result.success(null)
                    }
                    "battery" -> {
                        val manager = getSystemService(Context.BATTERY_SERVICE) as BatteryManager
                        val charging = Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && manager.isCharging
                        result.success(
                            mapOf(
                                "level" to manager.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY),
                                "charging" to charging,
                            ),
                        )
                    }
                    "saveImage" -> {
                        val bytes = call.argument<ByteArray>("bytes")
                        val name = call.argument<String>("name")
                        val mime = call.argument<String>("mime")
                        if (bytes == null || name == null || mime == null) {
                            result.error("bad_arguments", "参数不完整", null)
                            return@setMethodCallHandler
                        }
                        // 写文件放到后台线程，结果回到主线程返回
                        Thread {
                            try {
                                val location = saveImage(bytes, name, mime)
                                runOnUiThread { result.success(location) }
                            } catch (error: Exception) {
                                runOnUiThread { result.error("save_failed", error.message, null) }
                            }
                        }.start()
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /** 保存到“图片/HitomiViewer”，返回给用户看的位置。 */
    private fun saveImage(bytes: ByteArray, name: String, mime: String): String {
        val relative = "${Environment.DIRECTORY_PICTURES}/HitomiViewer"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // Android 10 起通过媒体库写入，不需要存储权限；重名时系统会自动改名
            val values = ContentValues().apply {
                put(MediaStore.Images.Media.DISPLAY_NAME, name)
                put(MediaStore.Images.Media.MIME_TYPE, mime)
                put(MediaStore.Images.Media.RELATIVE_PATH, relative)
                put(MediaStore.Images.Media.IS_PENDING, 1)
            }
            val uri = contentResolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
                ?: throw IOException("无法在相册中创建文件")
            try {
                contentResolver.openOutputStream(uri)?.use { it.write(bytes) }
                    ?: throw IOException("无法写入文件")
                values.clear()
                values.put(MediaStore.Images.Media.IS_PENDING, 0)
                contentResolver.update(uri, values, null, null)
            } catch (error: Exception) {
                contentResolver.delete(uri, null, null)
                throw error
            }
            return "$relative/$name"
        }
        // Android 9 及以下需要存储权限
        if (checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            runOnUiThread {
                requestPermissions(arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE), 1)
            }
            throw SecurityException("需要存储权限，允许后请再保存一次")
        }
        val directory = File(
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES),
            "HitomiViewer",
        )
        directory.mkdirs()
        var file = File(directory, name)
        var index = 2
        while (file.exists()) {
            file = File(directory, "${name.substringBeforeLast('.')} ($index).${name.substringAfterLast('.')}")
            index++
        }
        file.writeBytes(bytes)
        MediaScannerConnection.scanFile(this, arrayOf(file.absolutePath), arrayOf(mime), null)
        return file.absolutePath
    }
}
