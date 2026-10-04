# ProGuard/R8 rules for Watchtower.
#
# Release builds run R8 (code shrinking + obfuscation) and the resource shrinker.
# The Flutter/Dart code is compiled by Dart AOT and needs no rules; these cover the
# Android-side plugins.

# --- flutter_local_notifications -------------------------------------------------
# Serialises its notification models with Gson, which reflects over class and field
# names, so the models must survive shrinking and obfuscation.
-keep class com.dexterous.flutterlocalnotifications.** { *; }

# Receivers the plugin registers for scheduled notifications and actions are
# resolved by class name.
-keep class com.dexterous.flutterlocalnotifications.ScheduledNotificationReceiver { *; }
-keep class com.dexterous.flutterlocalnotifications.ScheduledNotificationBootReceiver { *; }
-keep class com.dexterous.flutterlocalnotifications.ActionBroadcastReceiver { *; }

# --- flutter_foreground_task -----------------------------------------------------
-keep class com.pravera.flutter_foreground_task.** { *; }

# --- Gson ------------------------------------------------------------------------
# Standard reflective-Gson keeps.
-keepattributes Signature
-keepattributes *Annotation*
-keep class com.google.gson.reflect.TypeToken { *; }
-keep class * extends com.google.gson.reflect.TypeToken
-keepclassmembers,allowobfuscation class * {
    @com.google.gson.annotations.SerializedName <fields>;
}
