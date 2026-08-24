@preconcurrency import AVFoundation
import Foundation

/// 将硬件原生音频流转换为云端 ASR 约定的 16 kHz / mono / Int16 PCM。
/// 实例只能在创建它的单一音频 Tap 回调中使用。
final class StreamingASRPCMConverter {
    private final class InputFeeder: @unchecked Sendable {
        let input: AVAudioPCMBuffer
        private var supplied = false

        init(input: AVAudioPCMBuffer) {
            self.input = input
        }

        func next(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            guard !supplied else {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
    }

    static let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    )!

    private let converter: AVAudioConverter
    private let inputSampleRate: Double

    init?(inputFormat: AVAudioFormat) {
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let converter = AVAudioConverter(from: inputFormat, to: Self.outputFormat) else {
            return nil
        }
        self.converter = converter
        self.inputSampleRate = inputFormat.sampleRate
    }

    func convert(_ input: AVAudioPCMBuffer) -> Data? {
        let ratio = Self.outputFormat.sampleRate / inputSampleRate
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio) + 32)
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.outputFormat, frameCapacity: capacity) else {
            return nil
        }

        let feeder = InputFeeder(input: input)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            feeder.next(status: inputStatus)
        }

        guard conversionError == nil, status != .error, output.frameLength > 0 else { return nil }
        return Self.data(fromCanonicalBuffer: output)
    }

    static func data(fromCanonicalBuffer buffer: AVAudioPCMBuffer) -> Data? {
        guard buffer.format.commonFormat == .pcmFormatInt16,
              buffer.format.sampleRate == outputFormat.sampleRate,
              buffer.format.channelCount == 1,
              let pointer = buffer.int16ChannelData?.pointee else { return nil }
        return Data(bytes: pointer, count: Int(buffer.frameLength) * MemoryLayout<Int16>.size)
    }
}

/// 音频格式转换器
/// 将 PCM 原始音频数据包装为标准 WAV 格式，适用于 DashScope 语音识别等场景
enum AudioConverter {

    // MARK: - 一次性转换

    /// 将 PCM 数据包装为完整 WAV 文件数据
    /// - Parameters:
    ///   - pcmData: PCM 原始音频数据
    ///   - sampleRate: 采样率（默认 16000，符合 DashScope 要求）
    ///   - channels: 声道数（默认 1，单声道）
    ///   - bitsPerSample: 采样位深（默认 16）
    /// - Returns: 包含 44 字节 RIFF header 的完整 WAV 数据
    static func wrapPCMToWAV(
        _ pcmData: Data,
        sampleRate: UInt32,
        channels: UInt16 = 1,
        bitsPerSample: UInt16 = 16
    ) -> Data {
        let header = WAVHeaderBuilder(
            sampleRate: sampleRate,
            channels: channels,
            bitsPerSample: bitsPerSample,
            pcmDataSize: UInt32(pcmData.count)
        ).build()

        var wavData = Data()
        wavData.append(header)
        wavData.append(pcmData)
        return wavData
    }
}

// MARK: - WAV Header 构建器

/// 支持流式场景的 WAV 文件头构建器
/// 可先生成 header，后续追加 PCM 数据
struct WAVHeaderBuilder {
    let sampleRate: UInt32
    let channels: UInt16
    let bitsPerSample: UInt16
    let pcmDataSize: UInt32

    /// 初始化 WAV 头构建器
    /// - Parameters:
    ///   - sampleRate: 采样率
    ///   - channels: 声道数
    ///   - bitsPerSample: 采样位深
    ///   - pcmDataSize: PCM 数据字节数（流式场景可先传 0，后续更新）
    init(
        sampleRate: UInt32,
        channels: UInt16 = 1,
        bitsPerSample: UInt16 = 16,
        pcmDataSize: UInt32 = 0
    ) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitsPerSample = bitsPerSample
        self.pcmDataSize = pcmDataSize
    }

    /// 构建 44 字节标准 WAV RIFF header
    func build() -> Data {
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample) / 8
        let blockAlign = channels * bitsPerSample / 8
        let totalSize = pcmDataSize + 36

        var header = Data()

        // ChunkID: "RIFF"
        header.append(contentsOf: "RIFF".utf8)
        // ChunkSize: 4 + (8 + SubChunk1Size) + (8 + SubChunk2Size)
        header.append(contentsOf: totalSize.toLittleEndianBytes())
        // Format: "WAVE"
        header.append(contentsOf: "WAVE".utf8)

        // Subchunk1ID: "fmt "
        header.append(contentsOf: "fmt ".utf8)
        // Subchunk1Size: 16 for PCM
        header.append(contentsOf: UInt32(16).toLittleEndianBytes())
        // AudioFormat: 1 for PCM
        header.append(contentsOf: UInt16(1).toLittleEndianBytes())
        // NumChannels
        header.append(contentsOf: channels.toLittleEndianBytes())
        // SampleRate
        header.append(contentsOf: sampleRate.toLittleEndianBytes())
        // ByteRate
        header.append(contentsOf: byteRate.toLittleEndianBytes())
        // BlockAlign
        header.append(contentsOf: blockAlign.toLittleEndianBytes())
        // BitsPerSample
        header.append(contentsOf: bitsPerSample.toLittleEndianBytes())

        // Subchunk2ID: "data"
        header.append(contentsOf: "data".utf8)
        // Subchunk2Size: PCM data size
        header.append(contentsOf: pcmDataSize.toLittleEndianBytes())

        return header
    }

    /// 更新 PCM 数据大小后重新构建 header（用于流式场景结束后补全文件大小）
    func withPCMDataSize(_ size: UInt32) -> WAVHeaderBuilder {
        WAVHeaderBuilder(
            sampleRate: sampleRate,
            channels: channels,
            bitsPerSample: bitsPerSample,
            pcmDataSize: size
        )
    }
}

// MARK: - 数值类型扩展

private extension UInt16 {
    func toLittleEndianBytes() -> [UInt8] {
        var value = self.littleEndian
        return withUnsafeBytes(of: &value) { Array($0) }
    }
}

private extension UInt32 {
    func toLittleEndianBytes() -> [UInt8] {
        var value = self.littleEndian
        return withUnsafeBytes(of: &value) { Array($0) }
    }
}
