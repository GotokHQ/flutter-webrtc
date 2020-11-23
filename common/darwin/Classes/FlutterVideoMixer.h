#import "SamplesInterceptor.h"
#import "FlutterVideoMixerRenderer.h"

typedef void (^FlutterVideoMixerSuccessCallback)(void);
typedef void (^FlutterVideoMixerErrorCallback)(NSString *errorType, NSString *errorMessage);

@interface FlutterVideoMixer : NSObject<CameraSwitchObserver>

@property(nonatomic, readonly) int fps;
@property(nonatomic, weak) id<SamplesInterceptorDelegate> delegate;
@property(nonatomic, readonly) dispatch_queue_t videoQueue;

-(instancetype)initWithDelegate:(__weak id<SamplesInterceptorDelegate>)delegate size:(CGSize)size framesPerSecond:(int)fps
NS_DESIGNATED_INITIALIZER;

- (void)startCaptureWithCompletion:(FlutterVideoMixerSuccessCallback)onComplete onError:(FlutterVideoMixerErrorCallback)onError;
- (void)stopCaptureWithCompletion:(FlutterVideoMixerSuccessCallback)onComplete onError:(FlutterVideoMixerErrorCallback)onError;
- (void)onAddVideoTrack:(RTCVideoTrack *)track isRemote:(BOOL)remote label:(NSString*)label;
- (void)onRemoveVideoTrack:(RTCVideoTrack *)track isRemote:(BOOL)remote label:(NSString*)label;
@end
