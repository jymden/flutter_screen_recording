#import "FSRSampleBufferAppender.h"

static NSString *const FSRSampleBufferAppenderErrorDomain =
    @"flutter_screen_recording.appender";

@implementation FSRSampleBufferAppender

+ (BOOL)appendSampleBuffer:(CMSampleBufferRef)sampleBuffer
                   toInput:(AVAssetWriterInput *)input
                     error:(NSError *_Nullable *_Nullable)error {
    @try {
        if ([input appendSampleBuffer:sampleBuffer]) {
            return YES;
        }

        if (error != NULL) {
            *error = [NSError
                errorWithDomain:FSRSampleBufferAppenderErrorDomain
                           code:1
                       userInfo:@{
                           NSLocalizedDescriptionKey :
                               @"appendSampleBuffer: returned NO"
                       }];
        }
        return NO;
    } @catch (NSException *exception) {
        if (error != NULL) {
            NSString *description = [NSString
                stringWithFormat:@"%@: %@", exception.name,
                                 exception.reason ?: @"unknown reason"];
            *error = [NSError
                errorWithDomain:FSRSampleBufferAppenderErrorDomain
                           code:2
                       userInfo:@{NSLocalizedDescriptionKey : description}];
        }
        return NO;
    }
}

@end
