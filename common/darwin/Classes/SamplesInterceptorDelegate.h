//
//  FlutterRecordDelegate.h
//  Pods
//
//  Created by Onyemaechi Okafor on 1/23/19.
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN


RTC_OBJC_EXPORT
@protocol SamplesInterceptorDelegate <NSObject>

- (void)didCaptureVideoSamples:(CVPixelBufferRef)pixelBuffer atTime:(CMTime)time rotation:(RTCVideoRotation)rotation;
- (void)didCaptureAudioSamples:(CMSampleBufferRef)audioSample;
- (void)didAudioCaptureFailWithError:(NSError *)error;
- (void)didVideoCaptureFailWithError:(NSError *)error;
@end

NS_ASSUME_NONNULL_END
