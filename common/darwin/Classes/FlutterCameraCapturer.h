#include <WebRTC/RTCVideoSource.h>
#import "FlutterVideoCapturer.h"
#import "FlutterCamera.h"

RTC_EXTERN NSString * const kRTCMediaConstraintsMinWidth;
RTC_EXTERN NSString * const kRTCMediaConstraintsMinHeight;

// Controls the camera. Handles starting the capture, switching cameras etc.
@interface FlutterCameraCapturer : NSObject<FlutterVideoCapturer>

@property(readonly, nonatomic) FlutterCamera* camera;
@property(readonly, nonatomic) BOOL audioEnabled;
- (instancetype)initWithVideoSource:(RTCVideoSource *)source
                        constraints:(NSDictionary *)constraints;

- (void)startCapture:(OnSuccess)success onError: (OnError)error;
- (void)stopCapture:(OnSuccess)success onError: (OnError)error;
- (void)switchCamera:(OnSuccess)success onError: (OnError)error;
- (void)restartCapture:(OnSuccess)success onError: (OnError)onError;
- (void)stopRunning:(OnSuccess)success onError: (OnError)onError;
- (void)startRunning:(OnSuccess)success onError: (OnError)onError;
@end
