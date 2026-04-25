#import <Foundation/Foundation.h>
#import <AVFAudio/AVFAudio.h>

NS_ASSUME_NONNULL_BEGIN

/// Wraps -[AVAudioNode installTapOnBus:bufferSize:format:block:] with @try/@catch so the
/// Obj-C NSException raised by AVAudioEngine on bad input state can be converted into a
/// Swift-catchable NSError. Swift do/try/catch cannot catch Obj-C exceptions; without this
/// bridge the exception aborts the process via SIGABRT.
@interface InstallTapBridge : NSObject

/// Returns YES on success. On failure (NSException raised), returns NO and populates `error`
/// with the exception's name + reason. The current engine instance must be considered
/// poisoned after a failure — callers should recreate the AVAudioEngine before retrying.
+ (BOOL)installTapOnNode:(AVAudioNode *)node
                     bus:(AVAudioNodeBus)bus
              bufferSize:(AVAudioFrameCount)bufferSize
                  format:(nullable AVAudioFormat *)format
                   block:(AVAudioNodeTapBlock)tapBlock
                   error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
