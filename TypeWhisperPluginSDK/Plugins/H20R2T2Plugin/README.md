# H20 R2T2 — TypeWhisper 转写插件

使用 Confucius4-R2T2 的 WebSocket 协议。WebSocket 地址与服务端密钥均在插件设置中填写，仓库和构建产物不包含服务端地址或密钥。

本插件实现 `TranscriptionEnginePlugin`，将 TypeWhisper 已录制的 16 kHz 单声道音频分 160 ms PCM16 帧发送，接收增量文本并拼接最终转写。当前未实现实时麦克风预览。

## 在线构建

在 GitHub 仓库 Actions 页面手动运行 **Build H20 R2T2 Plugin**，下载工作流产物 `H20R2T2Plugin-bundle`（内含 `H20R2T2Plugin.zip`）；解压后将 `H20R2T2Plugin.bundle` 放入 `~/Library/Application Support/TypeWhisper/Plugins/`，重启 TypeWhisper。此工作流构建未签名的测试 Bundle，不进行公证；若 macOS 阻止加载，先检查系统安全提示，不要关闭系统保护。

本地也可从 `TypeWhisper.xcodeproj` 构建 `H20R2T2Plugin` target。

## 设置

打开插件设置，填写 `ws://服务器:8272/asr_stream_api_v1`（可信局域网）或 TLS 的 `wss://...` 地址，以及服务端发放的密钥。密钥使用 TypeWhisper 插件隔离的 macOS 钥匙串保存。选择识别语言后，在转写引擎中选择 H20 R2T2。服务端不支持翻译；可传入至多 4000 字符的 system prompt。

参考：[TypeWhisper 插件 SDK](https://github.com/TypeWhisper/typewhisper-mac/tree/main/TypeWhisperPluginSDK/Plugins)、[R2T2 WebSocket 客户端](https://github.com/netease-youdao/Confucius4-R2T2/blob/master/ws_client.py)。
