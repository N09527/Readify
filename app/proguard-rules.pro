# Preserve OpenCC4J dictionary resources and classes
-keep class com.github.houbb.opencc4j.** { *; }
-dontwarn com.github.houbb.opencc4j.**

# Preserve PDFBox-Android & 7-Zip-JBinding JNI classes
-keep class com.tom_roush.pdfbox.** { *; }
-dontwarn com.tom_roush.pdfbox.**
-keep class net.sf.sevenzipjbinding.** { *; }
-dontwarn net.sf.sevenzipjbinding.**
