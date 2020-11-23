#import <Foundation/Foundation.h>

#import <Flutter/Flutter.h>
#import <WebRTC/RTCVideoTrack.h>
#import "FlutterVideoCapturer.h"
#import "MetaDataOptions.h"

@protocol FlutterRecorder <NSObject, CameraSwitchObserver>

- (void)addVideoTrack:(RTCVideoTrack *)videoTrack isRemote:(BOOL)remote label:(NSString*)label;
- (void)removeVideoTrack:(RTCVideoTrack *)videoTrack isRemote:(BOOL)remote label:(NSString*)label;
- (void)startVideoRecordingAtPath:(NSString *)path result:(FlutterResult)result;
- (void)stopVideoRecordingWithResult:(FlutterResult)result;
- (void)setPaused:(BOOL)paused;
- (void)dispose;
@end

