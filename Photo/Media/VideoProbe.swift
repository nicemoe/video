import AVFoundation
import UIKit
import KSPlayer
import Libavformat
import Libavutil

enum VideoProbe {
    struct Info {
        var width: Int
        var height: Int
        var duration: Double
    }

    enum ProbeError: LocalizedError {
        case emptyFile, noVideo, noFrame, ffmpeg(Int32, stage: String)
        var errorDescription: String? {
            switch self {
            case .emptyFile: return "文件大小为 0 字节，尚无可读取的视频内容"
            case .noVideo: return "文件中没有可读取的视频轨道"
            case .noFrame: return "无法生成视频封面"
            case .ffmpeg(let code, let stage):
                var buffer = [CChar](repeating: 0, count: Int(AV_ERROR_MAX_STRING_SIZE))
                buffer.withUnsafeMutableBufferPointer { pointer in
                    _ = av_strerror(code, pointer.baseAddress, pointer.count)
                }
                return "\(stage)失败：\(String(cString: buffer))（\(code)）"
            }
        }
    }

    /// 元信息统一由 FFmpeg 读取；上传临时文件没有扩展名也按内容识别。
    static func inspect(_ url: URL) async throws -> Info {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        if values.fileSize == 0 { throw ProbeError.emptyFile }
        var context: UnsafeMutablePointer<AVFormatContext>?
        defer { avformat_close_input(&context) }
        let opened = avformat_open_input(&context, url.path, nil, nil)
        guard opened >= 0 else { throw ProbeError.ffmpeg(opened, stage: "打开视频文件") }
        guard let context else { throw ProbeError.noVideo }
        let found = avformat_find_stream_info(context, nil)
        guard found >= 0 else { throw ProbeError.ffmpeg(found, stage: "读取视频信息") }
        let index = av_find_best_stream(context, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        guard index >= 0, let stream = context.pointee.streams[Int(index)],
              let parameters = stream.pointee.codecpar else { throw ProbeError.noVideo }
        let rawDuration = context.pointee.duration
        let seconds = rawDuration > 0 ? Double(rawDuration) / Double(AV_TIME_BASE) : 0
        var width = Int(parameters.pointee.width)
        var height = Int(parameters.pointee.height)
        guard width > 0, height > 0 else { throw ProbeError.noVideo }
        let codec = parameters.pointee
        if let sideData = codec.coded_side_data {
            for i in 0..<Int(codec.nb_coded_side_data) {
                let item = sideData[i]
                if item.type == AV_PKT_DATA_DISPLAYMATRIX, item.size >= 9 * MemoryLayout<Int32>.size {
                    let angle = item.data.withMemoryRebound(to: Int32.self, capacity: 9) {
                        av_display_rotation_get($0)
                    }
                    if angle.isFinite, abs(Int(angle.rounded())) % 180 == 90 { swap(&width, &height) }
                }
            }
        }
        return Info(width: width, height: height, duration: seconds)
    }

    static func poster(for url: URL, maxPixel: Int, decoder: DecoderChoice) async throws -> UIImage {
        let software = decoder == .software
            || (decoder == .auto && MediaFormats.prefersSoftware(fileName: url.lastPathComponent))
        if software {
            let thumbnails = try await ThumbnailController(thumbnailCount: 1)
                .generateThumbnail(for: url, thumbWidth: Int32(maxPixel))
            guard let image = thumbnails.first?.image else { throw ProbeError.noFrame }
            return image
        }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        let time = duration.isFinite && duration > 0 ? min(0.5, duration / 2) : 0
        let cg = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
        return UIImage(cgImage: cg)
    }
}
