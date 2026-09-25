import Foundation
import SwiftUI
import TypeWhisperPluginSDK

private enum R2T2Error: LocalizedError {
    case invalidEndpoint
    case missingKey
    case emptyAudio
    case unsupportedTranslation
    case server(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "请配置 ws:// 或 wss:// 开头的 WebSocket 地址"
        case .missingKey: "请在插件设置中填写服务端密钥"
        case .emptyAudio: "音频为空"
        case .unsupportedTranslation: "R2T2 不支持翻译模式"
        case .server(let message): "R2T2 服务错误：\(message)"
        case .timedOut: "等待 R2T2 最终识别结果超时"
        }
    }
}

@objc(H20R2T2Plugin)
final class H20R2T2Plugin: NSObject, TranscriptionEnginePlugin, @unchecked Sendable {
    static let pluginId = "me.beeven.typewhisper.h20-r2t2"
    static let pluginName = "H20 R2T2"
    static let defaultEndpoint = ""
    private static let eos = "YOUDAO_ONETIME_ASR_STREAM_EOS"
    private static let sampleRate = 16_000
    private static let frameSamples = 2_560 // 160 ms

    private var host: HostServices?
    private var endpoint = defaultEndpoint
    private var secret = ""
    private var languageMode = "zhen"

    required override init() { super.init() }

    func activate(host: HostServices) {
        self.host = host
        endpoint = host.userDefault(forKey: "endpoint") as? String ?? Self.defaultEndpoint
        secret = host.loadSecret(key: "secret-key") ?? ""
        languageMode = host.userDefault(forKey: "language") as? String ?? "zhen"
    }

    func deactivate() {
        host = nil
        secret = ""
    }

    var providerId: String { Self.pluginId }
    var providerDisplayName: String { "H20 R2T2" }
    var isConfigured: Bool { !secret.isEmpty && Self.validURL(endpoint) != nil }
    var transcriptionModels: [PluginModelInfo] {
        [PluginModelInfo(id: "r2t2", displayName: "Confucius4-R2T2 (H20)")]
    }
    var selectedModelId: String? { "r2t2" }
    func selectModel(_ modelId: String) { /* 唯一模型 */ }
    var supportsTranslation: Bool { false }
    var supportsStreaming: Bool { false } // WebSocket 传输是流式；SDK 的实时麦克风预览另有接口

    @MainActor var settingsView: AnyView? { AnyView(R2T2Settings(plugin: self)) }

    fileprivate var settingsEndpoint: String { endpoint }
    fileprivate var settingsLanguage: String { languageMode }
    fileprivate var hasSecret: Bool { !secret.isEmpty }

    fileprivate func save(endpoint: String, language: String, newSecret: String) throws {
        guard Self.validURL(endpoint) != nil else { throw R2T2Error.invalidEndpoint }
        if !newSecret.isEmpty {
            try host?.storeSecret(key: "secret-key", value: newSecret)
            secret = newSecret
        }
        self.endpoint = endpoint
        languageMode = language
        host?.setUserDefault(endpoint, forKey: "endpoint")
        host?.setUserDefault(language, forKey: "language")
        host?.notifyCapabilitiesChanged()
    }

    private static func validURL(_ value: String) -> URL? {
        guard let url = URL(string: value),
              ["ws", "wss"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else { return nil }
        return url
    }

    func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
        if translate { throw R2T2Error.unsupportedTranslation }
        guard let url = Self.validURL(endpoint) else { throw R2T2Error.invalidEndpoint }
        guard !secret.isEmpty else { throw R2T2Error.missingKey }
        guard !audio.samples.isEmpty else { throw R2T2Error.emptyAudio }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        let session = URLSession(configuration: config)
        let socket = session.webSocketTask(with: url)
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil); session.invalidateAndCancel() }

        let chosenLanguage: String
        switch language?.lowercased() {
        case "zh", "zh-cn", "chinese": chosenLanguage = "Chinese"
        case "en", "en-us", "english": chosenLanguage = "English"
        default: chosenLanguage = languageMode
        }
        var header: [String: Any] = [
            "channels": 1, "sample_rate": Self.sampleRate,
            "requestId": UUID().uuidString, "language": chosenLanguage,
            "use_vad": false, "secret_key": secret, "mode": "slow"
        ]
        if let prompt, !prompt.isEmpty { header["system_prompt"] = String(prompt.prefix(4_000)) }
        let metadata = try JSONSerialization.data(withJSONObject: header)
        try await socket.send(.string(String(decoding: metadata, as: UTF8.self)))

        // 同时收包，避免发送长音频时服务端输出填满缓冲区。
        let receiver = Task { try await Self.collect(socket: socket) }
        do {
            for start in stride(from: 0, to: audio.samples.count, by: Self.frameSamples) {
                try Task.checkCancellation()
                let end = min(start + Self.frameSamples, audio.samples.count)
                var chunk = Self.pcm16(audio.samples[start..<end])
                if end == audio.samples.count && end - start < Self.frameSamples {
                    // 与官方 ws_client.py 一致：末帧追加 0.5 秒静音。
                    chunk.append(Data(count: Self.sampleRate / 2 * 2))
                }
                try await socket.send(.data(chunk))
            }
            try await socket.send(.string(Self.eos))
            let seconds = min(600.0, max(60.0, audio.duration * 2 + 30))
            let text = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { try await receiver.value }
                group.addTask {
                    try await Task.sleep(for: .seconds(seconds))
                    socket.cancel(with: .goingAway, reason: nil)
                    throw R2T2Error.timedOut
                }
                let value = try await group.next()!
                group.cancelAll()
                return value
            }
            return PluginTranscriptionResult(text: text, detectedLanguage: chosenLanguage == "zhen" ? nil : chosenLanguage)
        } catch {
            socket.cancel(with: .goingAway, reason: nil)
            receiver.cancel()
            throw error
        }
    }

    private static func pcm16(_ samples: ArraySlice<Float>) -> Data {
        var bytes = Data(capacity: samples.count * 2)
        for sample in samples {
            let value = sample.isFinite ? max(-1, min(1, sample)) : 0
            let signed = Int16((value * 32767).rounded())
            let bits = UInt16(bitPattern: signed)
            bytes.append(UInt8(truncatingIfNeeded: bits))
            bytes.append(UInt8(truncatingIfNeeded: bits >> 8))
        }
        return bytes
    }

    private static func collect(socket: URLSessionWebSocketTask) async throws -> String {
        var transcript = ""
        while true {
            let message: URLSessionWebSocketTask.Message
            do { message = try await socket.receive() }
            catch {
                if socket.closeCode == .normalClosure { return transcript }
                throw error
            }
            guard case .string(let body) = message,
                  let data = body.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            guard let status = object["status"] as? String else { continue } // 服务端会发送 {} 心跳
            if status == "error" { throw R2T2Error.server(object["msg"] as? String ?? "未知错误") }
            if status == "success", let msg = object["msg"] as? [String: Any] {
                if let fragment = msg["text"] as? String { transcript += fragment }
            }
        }
    }
}

private struct R2T2Settings: View {
    let plugin: H20R2T2Plugin
    @State private var endpoint: String
    @State private var language: String
    @State private var secret = ""
    @State private var notice = ""

    init(plugin: H20R2T2Plugin) {
        self.plugin = plugin
        _endpoint = State(initialValue: plugin.settingsEndpoint)
        _language = State(initialValue: plugin.settingsLanguage)
    }

    var body: some View {
        Form {
            TextField("ws://服务器:8272/asr_stream_api_v1", text: $endpoint)
            SecureField(plugin.hasSecret ? "密钥已保存（留空不更改）" : "服务端密钥", text: $secret)
            Picker("识别语言", selection: $language) {
                Text("自动（中英）").tag("zhen")
                Text("中文").tag("Chinese")
                Text("英文").tag("English")
            }
            Button("保存") {
                do {
                    try plugin.save(endpoint: endpoint, language: language, newSecret: secret)
                    secret = ""
                    notice = "已保存"
                } catch { notice = error.localizedDescription }
            }
            Text(notice).foregroundStyle(.secondary)
            Text("将录音发送到指定局域网服务。密钥保存在 macOS 钥匙串；服务器不支持翻译。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding()
        .frame(minWidth: 430)
    }
}
