plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "app.harbor.nativeplayer"
    compileSdk = 34

    defaultConfig {
        minSdk = 24
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }

    kotlinOptions {
        jvmTarget = "1.8"
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.12.0")
    // Media3 / ExoPlayer: plays the containers the Android WebView can't
    // (MKV with h264/h265, EAC3/AC3 where the device decodes them) using the
    // platform's hardware codecs — the Android counterpart of the iOS libmpv
    // plugin, but battery-friendly because decode stays in MediaCodec.
    implementation("androidx.media3:media3-exoplayer:1.3.1")
    implementation("androidx.media3:media3-exoplayer-hls:1.3.1")
    implementation("androidx.media3:media3-ui:1.3.1")
    implementation(project(":tauri-android"))
}
