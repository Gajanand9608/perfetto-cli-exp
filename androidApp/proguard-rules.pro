# Add project-specific ProGuard/R8 rules here.
#
# The optimized Android default rules are already applied from build.gradle.kts.
-keep class androidx.tracing.** { *; }
-dontwarn androidx.tracing.**
-keep class kotlin.** { *; }
-dontwarn kotlin.**
