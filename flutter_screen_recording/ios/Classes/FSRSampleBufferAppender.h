#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Bridges -[AVAssetWriterInput appendSampleBuffer:] into Swift safely.
///
/// `appendSampleBuffer:` reports some failures by returning NO, but reports
/// others by throwing an Objective-C NSException (for example when a sample
/// buffer has a non-numeric or out-of-range presentation timestamp). Swift
/// cannot catch NSExceptions with do/catch, so calling `append(_:)` directly
/// from Swift can crash the whole app. This helper wraps the call in
/// @try/@catch and converts every failure into an NSError instead.
@interface FSRSampleBufferAppender : NSObject

/// Appends `sampleBuffer` to `input`. Returns YES on success. On failure it
/// returns NO and, if `error` is non-NULL, sets it to describe the reason.
///
/// The explicit Swift name keeps the importer from auto-renaming this the way
/// it renames -[AVAssetWriterInput appendSampleBuffer:] to append(_:to:).
+ (BOOL)appendSampleBuffer:(CMSampleBufferRef)sampleBuffer
                   toInput:(AVAssetWriterInput *)input
                     error:(NSError *_Nullable *_Nullable)error
    NS_SWIFT_NAME(append(_:to:));

@end

NS_ASSUME_NONNULL_END
