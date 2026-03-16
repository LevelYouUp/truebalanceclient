# Flutter local notifications - Gson TypeToken requires generic signatures to be preserved.
# Without this, R8 strips them and causes a fatal crash on cancelAllNotifications / loadScheduledNotifications.
-keepattributes Signature
-keepattributes *Annotation*

# Keep Gson TypeToken and its subclasses intact so reflection works
-keep class com.google.gson.reflect.TypeToken { *; }
-keep class * extends com.google.gson.reflect.TypeToken

# Keep all flutter_local_notifications model classes used with Gson
-keep class com.dexterous.** { *; }

# Firebase / Crashlytics
-keepattributes SourceFile,LineNumberTable
-keep public class * extends java.lang.Exception
