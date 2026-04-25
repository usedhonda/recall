#import "InstallTapBridge.h"

NSString * const InstallTapBridgeErrorDomain = @"com.example.recall.InstallTapBridge";

@implementation InstallTapBridge

+ (BOOL)installTapOnNode:(AVAudioNode *)node
                     bus:(AVAudioNodeBus)bus
              bufferSize:(AVAudioFrameCount)bufferSize
                  format:(AVAudioFormat *)format
                   block:(AVAudioNodeTapBlock)tapBlock
                   error:(NSError **)error {
    @try {
        [node installTapOnBus:bus bufferSize:bufferSize format:format block:tapBlock];
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
            userInfo[NSLocalizedDescriptionKey] = exception.reason ?: @"installTap raised NSException";
            userInfo[@"NSExceptionName"] = exception.name ?: @"unknown";
            *error = [NSError errorWithDomain:InstallTapBridgeErrorDomain
                                         code:1
                                     userInfo:userInfo];
        }
        return NO;
    }
}

@end
