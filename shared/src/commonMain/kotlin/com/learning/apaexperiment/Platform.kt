package com.learning.apaexperiment

interface Platform {
    val name: String
}

expect fun getPlatform(): Platform