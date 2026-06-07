package com.learning.apaexperiment

import platform.Foundation.NSDate
import platform.UIKit.UIDevice

class IOSPlatform: Platform {
    override val name: String = UIDevice.currentDevice.systemName() + " " + UIDevice.currentDevice.systemVersion
}

actual fun getPlatform(): Platform = IOSPlatform()

internal actual fun getTimeMillis(): Long = (NSDate().timeIntervalSince1970 * 1_000).toLong()
