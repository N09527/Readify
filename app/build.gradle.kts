plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "com.inkflow.reader"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.inkflow.reader"
        minSdk = 33
        targetSdk = 36
        versionCode = 17
        versionName = "1.1.7-readify"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildFeatures {
        compose = true
    }

    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
            excludes += "/META-INF/DEPENDENCIES"
            excludes += "/META-INF/LICENSE*"
            excludes += "/META-INF/NOTICE*"
        }
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.16.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.9.0")
    implementation("androidx.activity:activity-compose:1.10.1")

    implementation(platform("androidx.compose:compose-bom:2025.05.00"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-graphics")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")

    // EPUB & MOBI/AZW3 HTML/XML parsing
    implementation("org.jsoup:jsoup:1.24.1")

    // Traditional / Simplified Chinese conversion (Taiwan standard via ZhTwConverterUtil)
    implementation("com.github.houbb:opencc4j:1.14.0")

    // PDF text extraction for PDF Reflow mode
    implementation("com.tom-roush:pdfbox-android:2.0.27.0")

    // RAR4 / RAR5 / 7z archive extraction for CBR comic archives (16KB ELF aligned)
    implementation("com.github.omicronapps:7-Zip-JBinding-4Android:Release-16.02-2.03")

    debugImplementation("androidx.compose.ui:ui-tooling")
}
