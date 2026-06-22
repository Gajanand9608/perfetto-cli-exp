package com.learning.apaexperiment

import android.content.Intent
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import org.junit.Assert.assertNotNull
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AppLaunchUiAutomatorTest {

    @Test
    fun coldStartAppLaunch() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val device = UiDevice.getInstance(instrumentation)
        val context = instrumentation.targetContext
        val packageName = context.packageName

        val launchIntent = context.packageManager.getLaunchIntentForPackage(packageName)
            ?.apply {
                addFlags(Intent.FLAG_ACTIVITY_CLEAR_TASK)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
        assertNotNull("Launch intent not found for $packageName", launchIntent)

        context.startActivity(launchIntent)
        device.wait(Until.hasObject(By.pkg(packageName).depth(0)), LAUNCH_TIMEOUT_MS)

        val buildVariantText = device.wait(
            Until.findObject(By.textContains("Build variant:")),
            POST_ANR_TIMEOUT_MS,
        )
        assertNotNull("App did not render after ANR window", buildVariantText)
    }

    private companion object {
        const val LAUNCH_TIMEOUT_MS = 5_000L
        const val POST_ANR_TIMEOUT_MS = 20_000L
    }
}
