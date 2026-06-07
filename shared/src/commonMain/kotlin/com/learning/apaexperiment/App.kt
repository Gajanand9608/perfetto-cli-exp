package com.learning.apaexperiment

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeContentPadding
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.time.TimeSource
import org.jetbrains.compose.resources.painterResource

import apaexperiment.shared.generated.resources.Res
import apaexperiment.shared.generated.resources.compose_multiplatform

@Composable
@Preview
fun App(buildVariant: String = "preview") {
    MaterialTheme {
        var showContent by remember { mutableStateOf(false) }
        var cpuTestRunning by remember { mutableStateOf(false) }
        var cpuTestResult by remember { mutableStateOf<Long?>(null) }
        val scope = rememberCoroutineScope()
        Column(
            modifier = Modifier
                .background(MaterialTheme.colorScheme.primaryContainer)
                .safeContentPadding()
                .fillMaxSize()
                .padding(16.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Button(onClick = { showContent = !showContent }) {
                Text("Click me!")
            }
            Text("Build variant: $buildVariant")
            Button(
                enabled = !cpuTestRunning,
                onClick = {
                    scope.launch {
                        cpuTestRunning = true
                        cpuTestResult = withContext(Dispatchers.Default) {
                            runHeavyCpuOperation()
                        }
                        cpuTestRunning = false
                    }
                },
            ) {
                Text(if (cpuTestRunning) "Running CPU test..." else "Run CPU test")
            }
            cpuTestResult?.let { result ->
                Text("CPU test result: $result")
            }
            AnimatedVisibility(showContent) {
                val greeting = remember { Greeting().greet() }
                Column(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Image(painterResource(Res.drawable.compose_multiplatform), null)
                    Text("Compose: $greeting")
                }
            }
        }
    }
}

fun runHeavyCpuOperation(durationMillis: Long = 10_000L): Long {
    val startTime = TimeSource.Monotonic.markNow()
    var seed = 0x5DEECE66DL
    var result = 0L

    while (startTime.elapsedNow().inWholeMilliseconds < durationMillis) {
        var candidate = seed or 1L
        repeat(5_000) {
            candidate = ((candidate * 1_664_525L) + 1_013_904_223L) and Long.MAX_VALUE
            result = result xor calculatePrimeWeightedValue(candidate)
        }
        seed = seed xor result
    }

    return result
}

private fun calculatePrimeWeightedValue(value: Long): Long {
    var divisor = 3L
    var checksum = value

    while (divisor * divisor <= value && divisor < 10_000L) {
        if (value % divisor == 0L) {
            checksum = checksum xor (divisor * 31L)
        }
        divisor += 2L
    }

    return checksum
}
