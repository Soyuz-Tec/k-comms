plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}
val nativePushQualified = providers.gradleProperty("nativePushQualified").orElse("false").get()
require(nativePushQualified in listOf("true", "false")) { "nativePushQualified must be exactly true or false" }
android {
    namespace = "com.soyuz.kcomms"
    compileSdk = 35
    buildToolsVersion = "35.0.0"
    defaultConfig {
        applicationId = "com.soyuz.kcomms"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0"
        buildConfigField("boolean", "NATIVE_PUSH_QUALIFIED", nativePushQualified)
        manifestPlaceholders["nativePushQualified"] = nativePushQualified
        for (name in listOf("application_id", "project_id", "sender_id", "api_key")) {
            resValue("string", "native_fcm_$name", providers.gradleProperty("nativeFcm_$name").orElse("").get())
        }
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }
    buildTypes {
        release {
            isMinifyEnabled = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            // Signing credentials are deliberately operator-owned. Release APK remains unsigned.
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    buildFeatures { compose = true; buildConfig = true }
    lint { abortOnError = true }
    testOptions { unitTests.isReturnDefaultValues = true }
}
dependencies {
    implementation(libs.firebase.messaging)
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.foundation)
    implementation(libs.compose.material)
    implementation(libs.activity.compose)
    implementation(libs.lifecycle.runtime)
    implementation(libs.lifecycle.compose)
    implementation(libs.lifecycle.viewmodel)
    implementation(libs.core)
    implementation(libs.telecom)
    implementation(libs.livekit)
    implementation(libs.okhttp)
    implementation(libs.json)
    implementation(libs.coroutines)
    testImplementation(libs.junit)
    testImplementation(libs.coroutines.test)
    testImplementation(libs.mockwebserver)
    testImplementation(libs.okhttp.tls)
    androidTestImplementation(libs.android.test)
    androidTestImplementation(libs.android.runner)
}
