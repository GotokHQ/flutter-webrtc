#import <objc/runtime.h>
#import "FlutterRTCVideoSource.h"
#import "FlutterVideoCapturer.h"
#import <WebRTC/RTCMediaConstraints.h>
#import <WebRTC/RTCLogging.h>

@implementation RTCVideoSource (Flutter)

- (id<FlutterVideoCapturer>) capturer
{
    return objc_getAssociatedObject(self, _cmd);
}

- (void)setCapturer:(id<FlutterVideoCapturer>)capturer
{
    objc_setAssociatedObject(self, @selector(capturer), capturer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@end
