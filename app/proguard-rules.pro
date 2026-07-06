# Add project specific ProGuard rules here.
# Keep data classes used for Gemini/backend JSON (de)serialization.
-keep class com.waylo.ai.** { *; }
-keep class com.waylo.guidance.** { *; }

# Readable stack traces from release crashes (Logcat is our only visibility — see CLAUDE.md).
-keepattributes SourceFile, LineNumberTable
-renamesourcefileattribute SourceFile

# converter-gson is a declared dependency; keep generic signatures/annotations so
# reflection-based (de)serialization works if/when it's wired up.
-keepattributes Signature, *Annotation*
-keep class sun.misc.Unsafe { *; }
