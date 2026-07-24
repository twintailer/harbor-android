plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "app.harbor.nativeplayer"
    compileSdk = 34

    defaultConfig {
        minSdk = 26
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }

    kotlinOptions {
        jvmTarget = "1.8"
        // libmpv 1.0.0 ships Kotlin 2.2 metadata while the Tauri Android
        // project compiles with Kotlin 1.9. MPVLib is a tiny, stable API, so
        // let the 1.9 compiler read the newer metadata instead of failing.
        freeCompilerArgs = freeCompilerArgs + "-Xskip-metadata-version-check"
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.12.0")
    // libmpv, the same engine the desktop and iOS builds use. ExoPlayer played
    // the files fine but renders only a fraction of ASS/SSA subtitle styling,
    // so subtitles never matched the desktop no matter how they were mapped.
    // libmpv brings libass, which makes every subtitle setting behave exactly
    // as it does on Windows/iOS. Hardware decode still goes through MediaCodec
    // (hwdec=mediacodec-copy), so the battery cost stays reasonable.
    implementation("dev.jdtech.mpv:libmpv:1.0.0")
    implementation(project(":tauri-android"))
}
