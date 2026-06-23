#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Bridges throwing AVAssetWriter / AVAssetWriterInput lifecycle calls into
/// Swift safely.
///
/// Several of these calls report misuse by throwing an Objective-C NSException
/// instead of returning an error. For example -startSessionAtSourceTime: throws
/// when handed a non-numeric time, and -addInput: / -markAsFinished throw when
/// called in the wrong state. Swift cannot catch NSExceptions with do/catch, so
/// calling them directly from Swift can crash the whole app. Each method below
/// wraps the call in @try/@catch and converts any failure into an NSError
/// instead. This mirrors FSRSampleBufferAppender, extending the same protection
/// to the writer setup and teardown paths.
@interface FSRAssetWriterBridge : NSObject

/// Adds `input` to `writer`. Returns YES on success, NO (with `error` set) on
/// failure. Call -canAddInput: first; this guards against the call still
/// throwing in an unexpected state.
+ (BOOL)addInput:(AVAssetWriterInput *)input
        toWriter:(AVAssetWriter *)writer
           error:(NSError *_Nullable *_Nullable)error
    NS_SWIFT_NAME(add(_:to:));

/// Starts `writer` and opens a session at `sourceTime`. Wraps both -startWriting
/// and -startSessionAtSourceTime: so a failure of either is reported instead of
/// thrown. Returns YES on success. `sourceTime` should already be validated as
/// numeric by the caller; this is a final safety net.
+ (BOOL)startWriting:(AVAssetWriter *)writer
        atSourceTime:(CMTime)sourceTime
               error:(NSError *_Nullable *_Nullable)error
    NS_SWIFT_NAME(startWriting(_:atSourceTime:));

/// Marks `input` as finished. Returns YES on success, NO (with `error` set) on
/// failure.
+ (BOOL)markInputAsFinished:(AVAssetWriterInput *)input
                      error:(NSError *_Nullable *_Nullable)error
    NS_SWIFT_NAME(markAsFinished(_:));

/// Invokes -finishWritingWithCompletionHandler: on `writer`. `completionHandler`
/// still runs asynchronously when writing completes. Returns YES if the call was
/// issued, NO (with `error` set) if issuing it threw. When NO is returned the
/// completion handler will not run, so the caller is responsible for cleanup.
+ (BOOL)finishWriting:(AVAssetWriter *)writer
    completionHandler:(void (^)(void))completionHandler
                error:(NSError *_Nullable *_Nullable)error
    NS_SWIFT_NAME(finishWriting(_:completionHandler:));

@end

NS_ASSUME_NONNULL_END
