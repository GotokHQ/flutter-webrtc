//
//  FlutterVideoMixerRenderer.m
//  Pods-Runner
//
//  Created by Onyemaechi Okafor on 9/1/19.
//

#import "FlutterVideoMixerRenderer.h"
#import <WebRTC/RTCCVPixelBuffer.h>
#import "FlutterRTCVideoSource.h"
#import "FlutterCameraCapturer.h"
#import "MTLRGBRenderer.h"
#import "MTLNV12Renderer.h"
#import "MTLI420Renderer.h"

@interface FlutterVideoMixerRenderer ()
@property(nonatomic) MTLI420Renderer *rendererI420;
@property(nonatomic) MTLNV12Renderer *rendererNV12;
@property(nonatomic) MTLRGBRenderer *rendererRGB;
@end

@implementation FlutterVideoMixerRenderer{
    int64_t _lastDrawnFrameTimeStampNs;
    BOOL _usingFrontCamera;
    BOOL _firstFrameRendered;
    dispatch_semaphore_t _frameRenderingSemaphore;
    GPUImageRotationMode _gpuRotation;
    id<MTLTexture> _texture;
    id<MTLDevice> _device;
    MTLRenderPassDescriptor *_renderPassDescriptor;
    id<MTLBuffer> _vertexBuffer;
    MTLViewport _viewPort;
    RTCVideoViewObjectFit _objectFit;
}

@synthesize texture  = _texture;
@synthesize gpuRotation = _gpuRotation;
@synthesize firstFrameRendered = _firstFrameRendered;
@synthesize vertexBuffer = _vertexBuffer;
@synthesize objectFit = _objectFit;

-(instancetype)initWithdDevice:(id<MTLDevice>)device track:(RTCVideoTrack*)track isRemote:(BOOL)remote label:(NSString *)label{
    if (self = [super init]) {
        _device = device;
        _bounds = CGRectZero;
        _mirror = NO;
        _usingFrontCamera = NO;
        _firstFrameRendered = NO;
        _remote = remote;
        _label = label;
        _frameRenderingSemaphore = dispatch_semaphore_create(1);
        _renderPassDescriptor = [MTLRenderPassDescriptor new];
        // _renderPassDescriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
        _renderPassDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
        float vertexBufferArray[16] = {0};
        _vertexBuffer = [_device newBufferWithBytes:vertexBufferArray
                                             length:sizeof(vertexBufferArray)
                                            options:MTLResourceCPUCacheModeWriteCombined];
        _objectFit = RTCVideoViewObjectFitCover;
    }
    [self setTrack:track];
    return self;
}

- (void)teardownGL {
    [self destroyDataFBO];
}

#pragma mark -
#pragma mark Frame rendering

+ (MTLNV12Renderer *)createNV12Renderer:(id<MTLDevice>)device descriptor:(MTLRenderPassDescriptor*)descriptor {
    return [[MTLNV12Renderer alloc] initWithDevice:device descriptor:descriptor];
}

+ (MTLRGBRenderer *)createRGBRenderer:(id<MTLDevice>)device descriptor:(MTLRenderPassDescriptor*)descriptor {
    return [[MTLRGBRenderer alloc] initWithDevice:device descriptor:descriptor];
}
+ (MTLI420Renderer *)createI420Renderer:(id<MTLDevice>)device descriptor:(MTLRenderPassDescriptor*)descriptor {
    return [[MTLI420Renderer alloc] initWithDevice:device descriptor:descriptor];
}

- (void)createDataFBO {
    MTLTextureDescriptor* textureDescriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:_frameSize.width height:_frameSize.width mipmapped:NO];
     textureDescriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
     _texture = [_device newTextureWithDescriptor:textureDescriptor];
     NSAssert(_texture, @"Could not create texture of size: (%f), (%f)", _frameSize.width, _frameSize.width);
}

- (void)destroyDataFBO;
{
    _texture = nil;
}


- (void)setSize:(CGSize)size {
    if(!_texture || (size.width != _frameSize.width || size.height != _frameSize.height))
    {
        _frameSize = size;
        getCubeVertexDataWithObjectFit(
                                       _frameSize.width,
                                       _frameSize.height,
                                       kGPUImageNoRotation,
                                       _objectFit,
                                       self.bounds.size.width,
                                       self.bounds.size.height,
                                       (float *)_vertexBuffer.contents);
        if (_texture) {
            [self destroyDataFBO];
            [self createDataFBO];
        } else {
            [self createDataFBO];
        }
    }
}

- (void)setBounds:(CGRect)bounds{
    if(!CGRectEqualToRect(bounds, _bounds))
    {
        _bounds = bounds;
        getCubeVertexDataWithObjectFit(
                                       _frameSize.width,
                                       _frameSize.height,
                                       kGPUImageNoRotation,
                                       _objectFit,
                                       _bounds.size.width,
                                       _bounds.size.height,
                                       (float *)_vertexBuffer.contents);
    }
}

- (void)setObjectFit:(RTCVideoViewObjectFit)objectFit{
    if(objectFit != _objectFit)
    {
        _objectFit = objectFit;
        getCubeVertexDataWithObjectFit(
                                       _frameSize.width,
                                       _frameSize.height,
                                       kGPUImageNoRotation,
                                       _objectFit,
                                       _bounds.size.width,
                                       _bounds.size.height,
                                       (float *)_vertexBuffer.contents);
    }
}

- (void)setTrack:(RTCVideoTrack *)track {
    RTCVideoTrack *oldValue = self.track;
    if (oldValue != track) {
        if (oldValue) {
            [oldValue removeRenderer:self];
        }
        _track = track;
        if (_track) {
            RTCVideoSource *source = _track.source;
            if (source.capturer) {
                _mirror = source.capturer.facing;
                _usingFrontCamera = _mirror;
            }
            [_track addRenderer:self];
        }
        
    }
}

- (void)switchTrack:(BOOL)add {
    if (!_track) {
        return;
    }
    if (add) {
        [_track addRenderer:self];
    }else {
        [_track removeRenderer:self];
    }
}

- (void)renderFrame:(nullable RTCVideoFrame *)frame{
//    if (dispatch_semaphore_wait(_frameRenderingSemaphore, DISPATCH_TIME_NOW) != 0)
//    {
//        return;
//    }
//    __weak FlutterVideoMixerRenderer *weakSelf = self;
//    dispatch_async([FlutterGLContext sharedContextQueue], ^{
//        FlutterVideoMixerRenderer *strongSelf = weakSelf;
//        [strongSelf processFrame:frame];
//        dispatch_semaphore_signal(strongSelf->_frameRenderingSemaphore);
//    });
    [self processFrame:frame];
}


- (BOOL)processFrame:(nullable RTCVideoFrame *)frame{
    if (!frame) {
        NSLog(@"got null frame");
        return NO;
    }
    if (frame.timeStampNs == _lastDrawnFrameTimeStampNs) {
        NSLog(@"returning same frame");
        return NO;
    }
    int frameWidth = frame.width;
    int frameHeight = frame.height;
    if (frameWidth == 0 || frameHeight == 0) {
        return NO;
    }
    
    if (CGSizeEqualToSize(_frameSize, CGSizeZero)){
        return NO;
    }
    
    if (!_texture) {
        [self createDataFBO];
    }
    
    _gpuRotation = [self rtcRotationToGPURotation:frame.rotation];
    FlutterMTLRenderer *renderer;
    if ([frame.buffer isKindOfClass:[RTCCVPixelBuffer class]]) {
        RTCCVPixelBuffer *buffer = (RTCCVPixelBuffer*)frame.buffer;
        const OSType pixelFormat = CVPixelBufferGetPixelFormatType(buffer.pixelBuffer);
        if (pixelFormat == kCVPixelFormatType_32BGRA || pixelFormat == kCVPixelFormatType_32ARGB) {
            if (!self.rendererRGB) {
                self.rendererRGB = [FlutterVideoMixerRenderer createRGBRenderer:_device descriptor:_renderPassDescriptor];
            }
            renderer = self.rendererRGB;
        } else {
            if (!self.rendererNV12) {
                self.rendererNV12 = [FlutterVideoMixerRenderer createNV12Renderer:_device descriptor:_renderPassDescriptor];
            }
            renderer = self.rendererNV12;
        }
    } else {
        if (!self.rendererI420) {
            self.rendererI420 = [FlutterVideoMixerRenderer createI420Renderer:_device descriptor:_renderPassDescriptor];
        }
        renderer = self.rendererI420;
    }
    [renderer drawFrame:frame inTexture:_texture rotation:_gpuRotation];
    _lastDrawnFrameTimeStampNs = frame.timeStampNs;
    _firstFrameRendered = YES;
    return YES;
}

-(GPUImageRotationMode)rtcRotationToGPURotation:(RTCVideoRotation )rotation{
    return [FlutterGLFilter rtcRotationToGPURotation:rotation mirror:_mirror usingFrontCamera:_usingFrontCamera];
}


-(GPUImageRotationMode)gpuRotation {
    return _gpuRotation;
}

- (BOOL)isEqual:(id)object {
    if (self == object) {
        return YES;
    }
    if (![object isMemberOfClass:[self class]]) {
        return NO;
    }
    FlutterVideoMixerRenderer* other = (FlutterVideoMixerRenderer *)object;
    return [self isEqualTrack:other] && self.remote == other.remote;
}

- (BOOL)isEqualTrack:(FlutterVideoMixerRenderer *)renederer {
    if (!renederer) {
        return NO;
    }
    return [self.track isEqual:renederer.track];
}

- (void)dealloc{
    self.videoFrame = nil;
    _rendererI420 = nil;
    _rendererNV12 = nil;
    _rendererRGB = nil;
    NSLog(@"flutter video renderer deallocated");
    [_track removeRenderer:self];
    [self teardownGL];
}

@end
