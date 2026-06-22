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
class CriticalFlowUiAutomatorTest {

    @Test
    fun runLaggyCpuCriticalFlow() {
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
        device.wait(Until.findObject(By.textContains("Build variant:")), LAUNCH_TIMEOUT_MS)

        val cpuButton = device.wait(Until.findObject(By.text("Run CPU test")), LAUNCH_TIMEOUT_MS)
        assertNotNull("Run CPU test button not found", cpuButton)

        cpuButton.click()

        val result = device.wait(
            Until.findObject(By.textStartsWith("CPU test result:")),
            CPU_TEST_TIMEOUT_MS,
        )
        assertNotNull("CPU test result not shown after laggy flow", result)
    }

    private companion object {
        const val LAUNCH_TIMEOUT_MS = 5_000L
        const val CPU_TEST_TIMEOUT_MS = 20_000L
    }
}
