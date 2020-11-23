//  SamplesInterceptor.h
//  Pods
//
//  Created by Onyemaechi Okafor on 1/23/19.
//
#import "FlutterWebRTCPlugin.h"
#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import "SamplesInterceptorDelegate.h"

@interface SamplesInterceptor : NSObject<SamplesInterceptorDelegate>

- (void)addSampleInterceptor:(id<SamplesInterceptorDelegate>)intercepto;
- (void)removeSampleInterceptor:(id<SamplesInterceptorDelegate>)intercepto;

@end
