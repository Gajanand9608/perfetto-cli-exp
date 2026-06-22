package com.learning.apaexperiment

import android.util.Log
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.runBlocking

object AppLaunchInitManager {

    private const val TAG = "AppLaunchInit"

    fun onAppLaunchSync() {
        Log.d(TAG, "onAppLaunchSync started")
        launchSync {
            add { "INIT_NETWORK_CONFIG" to setupNetworkConfiguration() }
            add { "INIT_DEVICE_ID" to initDeviceId() }
            add { "INIT_SOURCE_FLOW" to initializeSourceFlow() }
            add { "INIT_USER_SESSION" to initUserSession() }
            add { "INIT_ANALYTICS" to initAnalytics() }
        }
        Log.d(TAG, "onAppLaunchSync completed")
    }

    private fun launchSync(
        block: MutableList<suspend () -> Pair<String, Any?>>.() -> Unit,
    ) {
        val tasks = mutableListOf<suspend () -> Pair<String, Any?>>().apply(block)
        runBlocking {
            tasks.map { task ->
                async { task() }
            }.awaitAll()
        }
    }

    private suspend fun setupNetworkConfiguration(): Any? {
        Log.d(TAG, "setupNetworkConfiguration started")
//        Thread.sleep(3_000)
        fibo(50)
        Log.d(TAG, "setupNetworkConfiguration done")
        return "https://api.example.com"
    }

    private suspend fun initDeviceId(): Any? {
        Log.d(TAG, "initDeviceId started")
//        Thread.sleep(2_000)
        fibo(40)
        Log.d(TAG, "initDeviceId done")
        return "device-abc-123"
    }

    fun fibo(x : Long) : Long {
        if(x<= 1) return x
        return fibo(x-1) + fibo(x-2) + fibo(x-3)
    }

    private suspend fun initializeSourceFlow(): Any? {
        Log.d(TAG, "initializeSourceFlow started")
//        Thread.sleep(4_000)
        fibo(40)
        Log.d(TAG, "initializeSourceFlow done")
        return "organic"
    }

    private suspend fun initUserSession(): Any? {
        Log.d(TAG, "initUserSession started")
//        Thread.sleep(3_500)
        fibo(50)
        Log.d(TAG, "initUserSession done")
        return mapOf("userId" to "u-9876", "loggedIn" to true)
    }

    private suspend fun initAnalytics(): Any? {
        Log.d(TAG, "initAnalytics started")
//        Thread.sleep(2_500)
        fibo(50)
        Log.d(TAG, "initAnalytics done")
        return true
    }
}
