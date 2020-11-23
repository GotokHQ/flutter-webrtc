#import <Foundation/Foundation.h>
#import <WebRTC/RTCMacros.h>
#import <WebRTC/RTCVideoRenderer.h>
#import <WebRTC/RTCVideoFrame.h>
#import <WebRTC/RTCVideoTrack.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import "FlutterGLFilter.h"

@protocol FlutterMTLTextureHolder;

@interface FlutterVideoMixerRenderer : NSObject<RTCVideoRenderer, FlutterMTLTextureHolder>

-(instancetype)initWithdDevice:(id<MTLDevice>)device track:(RTCVideoTrack*)track isRemote:(BOOL)remote label:(NSString *)label;

@property (nonatomic, strong) RTCVideoTrack *track;
@property (atomic, strong) RTCVideoFrame *videoFrame;
@property (readwrite,nonatomic) CGRect bounds;
@property (readonly,nonatomic) CGSize frameSize;
@property (readonly, nonatomic) id<MTLTexture> texture;
@property (readonly, nonatomic) GPUImageRotationMode gpuRotation;
@property (nonatomic) BOOL mirror;
@property (nonatomic) BOOL remote;
@property (readonly, nonatomic) BOOL firstFrameRendered;
@property (nonatomic, strong) NSString *label;

// (BOOL)draw;
-(void)switchTrack:(BOOL)add;
@end


