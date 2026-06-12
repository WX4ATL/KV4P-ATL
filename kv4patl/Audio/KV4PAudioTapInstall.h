// SPDX-License-Identifier: GPL-3.0-or-later
#import <AVFAudio/AVFAudio.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^KV4PAudioTapBlock)(AVAudioPCMBuffer *buffer, AVAudioTime *when);

BOOL KV4PInstallAudioTap(AVAudioNode *node,
                         AVAudioNodeBus bus,
                         AVAudioFrameCount bufferSize,
                         AVAudioFormat * _Nullable format,
                         KV4PAudioTapBlock block,
                         NSString * _Nullable * _Nullable errorMessage);

NS_ASSUME_NONNULL_END
