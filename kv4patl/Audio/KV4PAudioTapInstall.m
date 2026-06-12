// SPDX-License-Identifier: GPL-3.0-or-later
#import "KV4PAudioTapInstall.h"

BOOL KV4PInstallAudioTap(AVAudioNode *node,
                         AVAudioNodeBus bus,
                         AVAudioFrameCount bufferSize,
                         AVAudioFormat * _Nullable format,
                         KV4PAudioTapBlock block,
                         NSString * _Nullable * _Nullable errorMessage) {
    @try {
        [node installTapOnBus:bus bufferSize:bufferSize format:format block:block];
        return YES;
    } @catch (NSException *exception) {
        if (errorMessage != NULL) {
            NSString *reason = exception.reason ?: @"No exception reason was provided.";
            *errorMessage = [NSString stringWithFormat:@"%@: %@", exception.name, reason];
        }
        return NO;
    }
}
