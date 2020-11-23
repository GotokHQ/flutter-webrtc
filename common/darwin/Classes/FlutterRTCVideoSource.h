#import <Foundation/Foundation.h>
#import "FlutterWebRTCPlugin.h"
#import "FlutterVideoCapturer.h"


@interface RTCVideoSource (Flutter)
@property (nonatomic, strong) id<FlutterVideoCapturer> capturer;
@end
