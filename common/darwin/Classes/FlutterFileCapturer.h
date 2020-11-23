#include <WebRTC/RTCVideoSource.h>
#import "FlutterVideoCapturer.h"

// Controls the camera. Handles starting the capture, switching cameras etc.
@interface FlutterFileCapturer : NSObject<FlutterVideoCapturer>

- (instancetype)initWithVideoSource:(RTCVideoSource *)source
                        constraints:(NSDictionary *)constraints;

- (void)startCapture:(OnSuccess)success onError: (OnError)error;
- (void)stopCapture:(OnSuccess)success onError: (OnError)error;
- (void)switchCamera:(OnSuccess)success onError: (OnError)error;

@end
