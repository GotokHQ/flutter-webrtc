#import <Foundation/Foundation.h>
#import <Flutter/Flutter.h>
#import "SamplesInterceptor.h"
#import "FlutterRecorder.h"

@interface FlutterRTCVideoRecorder : NSObject<SamplesInterceptorDelegate, FlutterStreamHandler, FlutterRecorder, CameraSwitchObserver>

-(nullable instancetype)initWithRecorderId:(NSNumber *_Nonnull)recorderId videoSize:(CGSize)size framesPerSecond:(int)fps messenger:(NSObject<FlutterBinaryMessenger>*_Nonnull)messenger audioOnly:(BOOL)audioOnly
NS_DESIGNATED_INITIALIZER;

- (nullable instancetype)init UNAVAILABLE_ATTRIBUTE;
+ (nullable instancetype)new UNAVAILABLE_ATTRIBUTE;

@property(nonatomic) FlutterEventSink _Nullable eventSink;
@property(nonatomic) FlutterEventChannel * _Nonnull eventChannel;

/** The running control start capture or stop capture*/
@property (nonatomic, assign, getter=isRunning) BOOL running;

@property(assign, nonatomic, getter=isPaused) BOOL pause;

/* The saveLocalVideo is save the local video */
@property (nonatomic, assign) BOOL saveLocalVideo;

/* The saveLocalVideoPath is save the local video  path */
@property (nonatomic, strong, nullable) NSURL *saveLocalVideoPath;

@end
