package com.sortr.sortr_flutter

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import com.sortr.sortr_flutter.mediastore.MediaStorePlugin

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 注册 MediaStore MethodChannel plugin（sortr/mediastore）—— 取代 SAF
        flutterEngine.plugins.add(MediaStorePlugin())
        // SafPlugin 保留备用（非媒体文件场景），当前不加载：
        // flutterEngine.plugins.add(com.sortr.sortr_flutter.saf.SafPlugin())
    }
}
