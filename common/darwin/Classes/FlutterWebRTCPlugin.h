#if TARGET_OS_IPHONE
#import <Flutter/Flutter.h>
#elif TARGET_OS_MAC
#import <FlutterMacOS/FlutterMacOS.h>
#endif
#import "FlutterRecorder.h"
#import "FlutterVideoCapturer.h"
#import "FlutterCameraCapturer.h"
#import <Foundation/Foundation.h>
#import <WebRTC/WebRTC.h>

@class FlutterRTCVideoRenderer;
@class FlutterRTCFrameCapturer;

@protocol RTCAudioSessionDelegate;

@interface FlutterWebRTCPlugin : NSObject<FlutterPlugin, RTCPeerConnectionDelegate, RTCAudioSessionDelegate>

@property (nonatomic, strong) RTCPeerConnectionFactory *peerConnectionFactory;
@property (nonatomic, strong) RTCPeerConnectionFactory *peerConnectionFactory2;
@property (nonatomic, strong) NSMutableDictionary<NSString *, RTCPeerConnection *> *peerConnections;
@property (nonatomic, strong) NSMutableDictionary<NSString *, RTCMediaStream *> *localStreams;
@property (nonatomic, strong) NSMutableDictionary<NSString *, RTCMediaStreamTrack *> *localTracks;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, FlutterRTCVideoRenderer *> *renders;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, id<FlutterRecorder>> *mediaRecorders;
#if TARGET_OS_IPHONE
@property (nonatomic, retain) UIViewController *viewController;/*for broadcast or ReplayKit */
#endif
@property (nonatomic, strong, readonly) dispatch_queue_t dispatchQueue;
@property (nonatomic, strong, readonly) NSHashTable* cameraListeners;
@property (nonatomic, strong) NSObject<FlutterBinaryMessenger>* messenger;
@property (nonatomic, strong) FlutterCameraCapturer *videoCapturer;
@property (nonatomic, strong) FlutterRTCFrameCapturer *frameCapturer;
@property (nonatomic) BOOL _usingFrontCamera;
@property (nonatomic) int _targetWidth;
@property (nonatomic) int _targetHeight;
@property (nonatomic) int _targetFps;

- (RTCMediaStreamTrack*)trackForId:(NSString*)trackId;
- (void)addCameraListener:(id<CameraSwitchObserver>)observer;
- (void)removeCameraListener:(id<CameraSwitchObserver>)observer;
- (RTCMediaStream*)streamForId:(NSString*)streamId peerConnectionId:(NSString *)peerConnectionId;
- (NSDictionary*)mediaStreamToMap:(RTCMediaStream *)stream ownerTag:(NSString*)ownerTag;
- (NSDictionary*)mediaTrackToMap:(RTCMediaStreamTrack*)track;
- (NSDictionary*)receiverToMap:(RTCRtpReceiver*)receiver;
- (NSDictionary*)transceiverToMap:(RTCRtpTransceiver*)transceiver;

@end
