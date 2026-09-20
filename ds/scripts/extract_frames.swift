import Foundation
import AVFoundation
import CoreGraphics
import ImageIO

let videoPath = "/Users/coi/Desktop/Renew/Fix/VideoMP4.MP4"
let outDir = "/Users/coi/Desktop/Renew/Fix/frames"

let fileManager = FileManager.default
try? fileManager.createDirectory(atPath: outDir, withIntermediateDirectories: true, attributes: nil)

let url = URL(fileURLWithPath: videoPath)
let asset = AVURLAsset(url: url)

let durationSeconds = CMTimeGetSeconds(asset.duration)
print("Video duration: \(durationSeconds) seconds")

let generator = AVAssetImageGenerator(asset: asset)
generator.appliesPreferredTrackTransform = true
generator.requestedTimeToleranceBefore = .zero
generator.requestedTimeToleranceAfter = .zero

// Extract up to 15 key frames evenly spaced across the video
let frameCount = 15
for i in 0..<frameCount {
    let t = durationSeconds * Double(i) / Double(frameCount - 1)
    let time = CMTime(seconds: t, preferredTimescale: 600)
    do {
        let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
        let outUrl = URL(fileURLWithPath: "\(outDir)/frame_\(String(format: "%02d", i))_at_\(Int(t))s.jpg")
        if let destination = CGImageDestinationCreateWithURL(outUrl as CFURL, "public.jpeg" as CFString, 1, nil) {
            let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.85]
            CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
            CGImageDestinationFinalize(destination)
            print("Saved frame \(i) at \(Int(t))s: \(outUrl.lastPathComponent)")
        }
    } catch {
        print("Failed to extract frame at \(t)s: \(error)")
    }
}
