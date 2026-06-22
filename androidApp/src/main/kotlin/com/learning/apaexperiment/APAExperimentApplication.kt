package com.learning.apaexperiment

import android.app.Application

class APAExperimentApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        AppLaunchInitManager.onAppLaunchSync()
    }
}
