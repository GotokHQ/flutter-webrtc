//
//  FlutterAudioMixer.h
//  Pods-Runner
//
//  Created by Onyemaechi Okafor on 9/1/19.
//

#import "SamplesInterceptor.h"
#import <WebRTC/RCAudioDeviceModule.h>
#import <WebRTC/RCAudioMixerObserver.h>

@interface FlutterAudioMixer : NSObject<RCAudioMixerObserver>

@property (nonatomic, strong) RCAudioDeviceModule* adm;
-(void)addAudioSamplesInterceptor:(id<SamplesInterceptorDelegate>)samplesInterceptor;
-(void)removeAudioSamplesInterceptor:(id<SamplesInterceptorDelegate>)samplesInterceptor;
@end
