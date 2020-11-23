#import <WebRTC/WebRTC.h>
#import "SamplesInterceptorDelegate.h"
#import "FlutterVideoCapturer.h"
#if TARGET_OS_IPHONE
@interface FlutterRPScreenRecorder : RTCVideoCapturer
@property(nonatomic, weak) id<SamplesInterceptorDelegate> _Nullable samplesInterceptorDelegate;
-(instancetype _Nullable )initWithDelegate:(__weak id<RTCVideoCapturerDelegate>_Nullable)delegate
             samplesInterceptor:(__weak id<SamplesInterceptorDelegate>_Nullable)interceptorDelegate;
- (void)startCapture:(nullable OnSuccess)onSuccess onError:(nullable OnError)onError;
- (void)stopCapture:(nullable  OnSuccess)onSuccess onError:(nullable OnError)onError;
@end
#endif
