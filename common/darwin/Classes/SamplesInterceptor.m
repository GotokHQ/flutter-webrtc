//
//  SamplesInterceptor.m
//  Pods-Runner
//
//  Created by Onyemaechi Okafor on 2/9/19.
//

#import "SamplesInterceptor.h"
#import "SamplesInterceptorDelegate.h"

@implementation SamplesInterceptor
{
    NSMutableArray<id<SamplesInterceptorDelegate>> *_interceptors;
}
- (instancetype)init{
    self = [super init];
    _interceptors = [[NSMutableArray alloc] init];
    return self;
}

-(void)addSampleInterceptor:(id<SamplesInterceptorDelegate>)interceptor{
    NSUInteger index = [_interceptors indexOfObjectIdenticalTo:interceptor];
    if (index == NSNotFound) {
        [_interceptors addObject:interceptor];
    }
}

-(void)removeSampleInterceptor:(id<SamplesInterceptorDelegate>)interceptor{
    NSUInteger index = [_interceptors indexOfObjectIdenticalTo:interceptor];
    if (index != NSNotFound) {
        [_interceptors removeObjectAtIndex:index];
    }

}

- (void)didCaptureVideoSamples:(CVPixelBufferRef)pixelBuffer atTime: (CMTime)time rotation:(RTCVideoRotation)rotation{
    for (id interceptor in _interceptors) {
        [interceptor didCaptureVideoSamples:pixelBuffer atTime:time rotation:rotation];
    }
}

- (void)didCaptureAudioSamples:(CMSampleBufferRef)audioSample {
    for (id interceptor in _interceptors) {
        [interceptor didCaptureAudioSamples:audioSample];
    }
}
@end
