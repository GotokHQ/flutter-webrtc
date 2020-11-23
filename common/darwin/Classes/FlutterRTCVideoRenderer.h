#import "FlutterWebRTCPlugin.h"
#import <WebRTC/WebRTC.h>
#import "FlutterGLFilter.h"

@protocol MTLTexture;

@protocol FrameListener <NSObject>
@property (readonly, nonatomic) CVPixelBufferRef renderTarget;
@property (readonly, nonatomic) BOOL hasFrameBuffer;
-(BOOL)drawWithTexture:(id<MTLTexture>)texture frameSize:(CGSize)size rotation:(GPUImageRotationMode)rotation;
@end

@interface FlutterRTCVideoRenderer : NSObject <FlutterTexture, RTCVideoRenderer, FlutterStreamHandler, CameraSwitchObserver>

/**
 * The {@link RTCVideoTrack}, if any, which this instance renders.
 */
@property (nonatomic, strong) RTCVideoTrack *videoTrack;
@property (nonatomic) int64_t textureId;
@property (nonatomic, weak) id<FlutterTextureRegistry> registry;
@property (nonatomic, strong) FlutterEventSink eventSink;
@property (atomic, strong) RTCVideoFrame *videoFrame;
@property (nonatomic) BOOL mirror;
@property (nonatomic) BOOL blur;
@property (nonatomic) BOOL mute;

- (void)dispose;

- (void)willSwitchCamera:(bool)isFacing trackId: (NSString*)trackid;
- (void)didSwitchCamera:(bool)isFacing trackId: (NSString*)trackid;
- (void)didFailSwitch:(NSString*)trackid;
- (void)snapshotWithResult:(FlutterResult)result;
- (void)addFrameListener:(id<FrameListener>)frameListener;
- (void)removeFrameListener:(id<FrameListener>)frameListener;
@end


@interface FlutterWebRTCPlugin (FlutterRTCVideoRenderer)

- (FlutterRTCVideoRenderer *)createWithTextureRegistry:(id<FlutterTextureRegistry>)registry;

-(void)rendererSetSrcObject:(FlutterRTCVideoRenderer*)renderer stream:(RTCVideoTrack*)videoTrack;

@end
