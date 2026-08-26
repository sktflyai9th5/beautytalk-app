package com.skt.beautytalk.beauty_talk

import android.content.Intent
import android.os.Build
import android.speech.ModelDownloadListener
import android.speech.RecognitionService
import android.speech.RecognitionSupport
import android.speech.RecognitionSupportCallback
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/// 온디바이스 음성 인식(STT) 진단·관리 채널.
///
/// speech_to_text 패키지가 노출하지 않는 Android 13+ API 를 쓴다:
///  - checkRecognitionSupport : 온디바이스 언어팩 설치/설치가능 상태 조회
///  - triggerModelDownload    : 한국어 온디바이스 모델 다운로드 요청
///  - 기기에 설치된 RecognitionService 목록 조회
class MainActivity : FlutterActivity() {
    private val channel = "beautytalk/stt_diag"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "listRecognizers" -> result.success(listRecognizers())
                    "onDeviceAvailable" ->
                        result.success(SpeechRecognizer.isOnDeviceRecognitionAvailable(this))
                    "checkSupport" -> checkSupport(call.argument<String>("locale") ?: "ko-KR", result)
                    "downloadModel" -> downloadModel(call.argument<String>("locale") ?: "ko-KR", result)
                    else -> result.notImplemented()
                }
            }
    }

    /// 기기에 설치된 android.speech.RecognitionService 구현체 목록
    private fun listRecognizers(): List<String> =
        packageManager
            .queryIntentServices(Intent(RecognitionService.SERVICE_INTERFACE), 0)
            .mapNotNull { it.serviceInfo?.let { s -> "${s.packageName}/${s.name}" } }

    /// 온디바이스 인식기가 어떤 언어를 지원/설치하고 있는지 조회 (Android 13+)
    private fun checkSupport(locale: String, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success(mapOf("error" to "requires Android 13+"))
            return
        }
        if (!SpeechRecognizer.isOnDeviceRecognitionAvailable(this)) {
            result.success(mapOf("error" to "on-device recognition unavailable"))
            return
        }
        val recognizer = SpeechRecognizer.createOnDeviceSpeechRecognizer(this)
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, locale)
        }
        var replied = false
        fun reply(v: Map<String, Any?>) {
            if (!replied) {
                replied = true
                runOnUiThread {
                    result.success(v)
                    recognizer.destroy()
                }
            }
        }
        recognizer.checkRecognitionSupport(
            intent,
            Executors.newSingleThreadExecutor(),
            object : RecognitionSupportCallback {
                override fun onSupportResult(support: RecognitionSupport) {
                    reply(
                        mapOf(
                            "installedOnDevice" to support.installedOnDeviceLanguages,
                            "pendingOnDevice" to support.pendingOnDeviceLanguages,
                            "supportedOnDevice" to support.supportedOnDeviceLanguages,
                            "online" to support.onlineLanguages,
                        )
                    )
                }

                override fun onError(error: Int) = reply(mapOf("error" to "code $error"))
            },
        )
    }

    /// 한국어 온디바이스 모델 다운로드 요청 (Android 13+)
    private fun downloadModel(locale: String, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success(mapOf("error" to "requires Android 13+"))
            return
        }
        val recognizer = SpeechRecognizer.createOnDeviceSpeechRecognizer(this)
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, locale)
        }
        var replied = false
        fun reply(v: Map<String, Any?>) {
            if (!replied) {
                replied = true
                runOnUiThread {
                    result.success(v)
                    recognizer.destroy()
                }
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            recognizer.triggerModelDownload(
                intent,
                Executors.newSingleThreadExecutor(),
                object : ModelDownloadListener {
                    override fun onProgress(completedPercent: Int) {
                        // 진행률은 로그로만 (필요하면 EventChannel 로 승격)
                        android.util.Log.i("SttDiag", "model download $completedPercent%")
                    }

                    override fun onSuccess() = reply(mapOf("status" to "downloaded"))
                    override fun onScheduled() = reply(mapOf("status" to "scheduled"))
                    override fun onError(error: Int) = reply(mapOf("error" to "code $error"))
                },
            )
        } else {
            @Suppress("DEPRECATION")
            recognizer.triggerModelDownload(intent)
            reply(mapOf("status" to "requested (Android 13)"))
        }
    }
}
