#import "FSRAssetWriterBridge.h"

static NSString *const FSRAssetWriterBridgeErrorDomain =
    @"flutter_screen_recording.assetwriter";

@implementation FSRAssetWriterBridge

+ (NSError *)errorWithDescription:(NSString *)description code:(NSInteger)code {
    return [NSError errorWithDomain:FSRAssetWriterBridgeErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey : description}];
}

+ (NSError *)errorFromException:(NSException *)exception {
    NSString *description =
        [NSString stringWithFormat:@"%@: %@", exception.name,
                                   exception.reason ?: @"unknown reason"];
    return [self errorWithDescription:description code:2];
}

+ (BOOL)addInput:(AVAssetWriterInput *)input
        toWriter:(AVAssetWriter *)writer
           error:(NSError *_Nullable *_Nullable)error {
    @try {
        [writer addInput:input];
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) {
            *error = [self errorFromException:exception];
        }
        return NO;
    }
}

+ (BOOL)startWriting:(AVAssetWriter *)writer
        atSourceTime:(CMTime)sourceTime
               error:(NSError *_Nullable *_Nullable)error {
    @try {
        if (![writer startWriting]) {
            if (error != NULL) {
                *error = writer.error
                             ?: [self errorWithDescription:@"startWriting returned NO"
                                                      code:1];
            }
            return NO;
        }
        [writer startSessionAtSourceTime:sourceTime];
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) {
            *error = [self errorFromException:exception];
        }
        return NO;
    }
}

+ (BOOL)markInputAsFinished:(AVAssetWriterInput *)input
                      error:(NSError *_Nullable *_Nullable)error {
    @try {
        [input markAsFinished];
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) {
            *error = [self errorFromException:exception];
        }
        return NO;
    }
}

+ (BOOL)finishWriting:(AVAssetWriter *)writer
    completionHandler:(void (^)(void))completionHandler
                error:(NSError *_Nullable *_Nullable)error {
    @try {
        [writer finishWritingWithCompletionHandler:completionHandler];
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) {
            *error = [self errorFromException:exception];
        }
        return NO;
    }
}

@end
