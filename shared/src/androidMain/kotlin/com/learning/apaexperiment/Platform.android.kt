package com.learning.apaexperiment

import android.os.Build

class AndroidPlatform : Platform {
    override val name: String = "Android ${Build.VERSION.SDK_INT}"
}

actual fun getPlatform(): Platform = AndroidPlatform()

internal actual fun getTimeMillis(): Long = System.currentTimeMillis()
