#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSString *videoPath = @"/Users/coi/Desktop/Renew/Fix/VideoMP4.MP4";
        NSString *outDir = @"/Users/coi/Desktop/Renew/Fix/frames";

        [[NSFileManager defaultManager] createDirectoryAtPath:outDir withIntermediateDirectories:YES attributes:nil error:nil];

        NSURL *url = [NSURL fileURLWithPath:videoPath];
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];

        Float64 durationSeconds = CMTimeGetSeconds(asset.duration);
        printf("Video duration: %.2f seconds\n", durationSeconds);

        AVAssetImageGenerator *generator = [[AVAssetImageGenerator alloc] initWithAsset:asset];
        generator.appliesPreferredTrackTransform = YES;
        generator.requestedTimeToleranceBefore = kCMTimeZero;
        generator.requestedTimeToleranceAfter = kCMTimeZero;

        int frameCount = 15;
        for (int i = 0; i < frameCount; i++) {
            Float64 t = (durationSeconds > 0) ? (durationSeconds * (double)i / (double)(frameCount - 1)) : 0;
            CMTime time = CMTimeMakeWithSeconds(t, 600);
            NSError *err = nil;
            CGImageRef cgImage = [generator copyCGImageAtTime:time actualTime:NULL error:&err];
            if (cgImage) {
                NSString *outPath = [NSString stringWithFormat:@"%@/frame_%02d_at_%ds.jpg", outDir, i, (int)t];
                NSURL *outUrl = [NSURL fileURLWithPath:outPath];
                CGImageDestinationRef dest = CGImageDestinationCreateWithURL((__bridge CFURLRef)outUrl, (CFStringRef)@"public.jpeg", 1, NULL);
                if (dest) {
                    NSDictionary *options = @{(__bridge NSString *)kCGImageDestinationLossyCompressionQuality: @(0.85)};
                    CGImageDestinationAddImage(dest, cgImage, (__bridge CFDictionaryRef)options);
                    CGImageDestinationFinalize(dest);
                    CFRelease(dest);
                    printf("Saved frame %d at %ds: %s\n", i, (int)t, [outPath UTF8String]);
                }
                CGImageRelease(cgImage);
            } else {
                printf("Error at %.1fs: %s\n", t, err ? [[err description] UTF8String] : "unknown");
            }
        }
    }
    return 0;
}
