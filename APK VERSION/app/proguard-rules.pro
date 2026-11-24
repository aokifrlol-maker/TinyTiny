-keepattributes Signature, *Annotation*, JavascriptInterface, InnerClasses, EnclosingMethod
-keep class com.bella.tinytiny.** { *; }
-keepclassmembers class * {
    @android.webkit.JavascriptInterface <methods>;
}
-keepclassmembers class **$$serializer { *; }
-dontwarn org.conscrypt.**
-dontwarn org.bouncycastle.**
-dontwarn org.openjsse.**
-dontwarn javax.annotation.**
