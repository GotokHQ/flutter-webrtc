#import "FlutterRTCVideoRenderer.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreGraphics/CGImage.h>
#import "MTLGaussianBlur.h"
#import "FlutterCameraCapturer.h"
#import "FlutterRTCVideoSource.h"
#import "FlutterVideoCapturer.h"
#import <objc/runtime.h>
#import "FlutterWebRTCPlugin.h"
#import "FlutterGLFilter.h"
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import "MTLRenderer.h"
#import "MTLRGBRenderer.h"
#import "MTLNV12Renderer.h"
#import "MTLI420Renderer.h"
#import "MTLColorSwizzleRenderer.h"

@interface FlutterRTCVideoRenderer ()
@property(nonatomic) MTLI420Renderer *rendererI420;
@property(nonatomic) MTLNV12Renderer *rendererNV12;
@property(nonatomic) MTLRGBRenderer *rendererRGB;
@property(nonatomic) MTLColorSwizzleRenderer *rendererColorSwizzle;
@property(nonatomic) MTLGaussianBlur *gaussBlur;
@end

//@todo move gpu processing off main queue
//implement object fit
@implementation FlutterRTCVideoRenderer {
    CGRect _bounds;
    CGSize _frameSize;
    CGSize _renderSize;
    CVPixelBufferRef _renderTarget;
    RTCVideoRotation _rotation;
    FlutterEventChannel* _eventChannel;
    int64_t _lastDrawnFrameTimeStampNs;
    BOOL _usingFrontCamera;
    BOOL _mute;
    BOOL _blur;
    NSMutableArray<id<FrameListener>> *_frameListeners;
    CVMetalTextureCacheRef _outTextureCache;
    id<MTLTexture> _outTexture;
    id<MTLTexture> _inTexture;
    id<MTLDevice> _device;
    dispatch_queue_t _videoQueue;
}

@synthesize textureId  = _textureId;
@synthesize registry = _registry;
@synthesize eventSink = _eventSink;
@synthesize blur = _blur;
@synthesize mute = _mute;


- (instancetype)initWithTextureRegistry:(id<FlutterTextureRegistry>)registry
                              messenger:(NSObject<FlutterBinaryMessenger>*)messenger{
    self = [super init];
    if (self){
        _frameSize = CGSizeZero;
        _renderSize = CGSizeZero;
        _registry = registry;
        _renderTarget = nil;
        _eventSink = nil;
        _rotation  = -1;
        _textureId  = [registry registerTexture:self];
        _eventChannel = [FlutterEventChannel
                         eventChannelWithName:[NSString stringWithFormat:@"FlutterWebRTC/Texture%lld", _textureId]
                         binaryMessenger:messenger];
        [_eventChannel setStreamHandler:self];
        _mirror = NO;
        _usingFrontCamera = NO;
        _mute = NO;
        _blur = NO;
        _frameListeners = [[NSMutableArray alloc] init];
        _videoQueue = dispatch_queue_create("FlutterWebRTC/FlutterRTCVideoRenderer", DISPATCH_QUEUE_SERIAL);
    }
    [self initGL];
    return self;
}

- (void)initGL {
    _device = MTLCreateSystemDefaultDevice();
    _gaussBlur = [[MTLGaussianBlur alloc] initWithDevice:_device];
    [self initializeTextureCache];
}

+ (MTLColorSwizzleRenderer *)createColorSwizzleThroughRenderer:(id<MTLDevice>)device {
    return [[MTLColorSwizzleRenderer alloc] initWithDevice:device];
}

+ (MTLNV12Renderer *)createNV12Renderer:(id<MTLDevice>)device {
    return [[MTLNV12Renderer alloc] initWithDevice:device];
}

+ (MTLRGBRenderer *)createRGBRenderer:(id<MTLDevice>)device {
    return [[MTLRGBRenderer alloc] initWithDevice:device];
}
+ (MTLI420Renderer *)createI420Renderer:(id<MTLDevice>)device {
    return [[MTLI420Renderer alloc] initWithDevice:device];
}
#pragma mark -
#pragma mark Frame rendering

- (BOOL)initializeTextureCache {
    CVReturn status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, _device,
                                       nil, &_outTextureCache);
    if (status != kCVReturnSuccess) {
        NSLog(@"Metal: Failed to initialize metal texture cache. Return status is %d", status);
        return NO;
    }
    return YES;
}

- (void)creatOutputFBO {
    CVMetalTextureRef textureOut;
    id<MTLTexture> gpuTexture = nil;
    
    if (!_outTextureCache) {
        [self initializeTextureCache];
        
    }
    NSDictionary* cvBufferProperties = @{
        (__bridge NSString*)kCVPixelBufferOpenGLCompatibilityKey : @YES,
        (__bridge NSString*)kCVPixelBufferMetalCompatibilityKey : @YES,
        (__bridge NSString*)kCVPixelBufferMetalCompatibilityKey : @{}
    };
    CVReturn err = CVPixelBufferCreate(kCFAllocatorDefault,
                                       _frameSize.width, _frameSize.height,
                                       kCVPixelFormatType_32BGRA,
                                       (__bridge CFDictionaryRef)cvBufferProperties,
                                       &_renderTarget);
    
    if (err)
    {
        //NSLog(@"FBO size: %f, %f", _frameSize.width, _frameSize.height);
        NSAssert(NO, @"Error at CVPixelBufferCreate %d", err);
    }
    
    err = CVMetalTextureCacheCreateTextureFromImage(
                                                                kCFAllocatorDefault, _outTextureCache, _renderTarget, nil, MTLPixelFormatBGRA8Unorm,
                                                                _frameSize.width, _frameSize.height, 0, &textureOut);

    if (err)
    {
        //NSLog(@"FBO size: %f, %f", _frameSize.width, _frameSize.height);
        NSAssert(NO, @"Error at CVMetalTextureCacheCreateTextureFromImage Failed %d", err);
    }
    gpuTexture = CVMetalTextureGetTexture(textureOut);
    CVBufferRelease(textureOut);
    _outTexture = gpuTexture;
}

- (void)createInterFBO {
   MTLTextureDescriptor* textureDescriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:_frameSize.width height:_frameSize.width mipmapped:NO];
    textureDescriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    _inTexture = [_device newTextureWithDescriptor:textureDescriptor];
    NSAssert(_inTexture, @"Could not create texture of size: (%f), (%f)", _frameSize.width, _frameSize.width);
}

- (void)createDataFBO {
    [self creatOutputFBO];
    [self createInterFBO];
}

- (void)destroyDataFBO;
{
    if (_renderTarget)
    {
        CVBufferRelease(_renderTarget);
    }
    if (_outTextureCache) {
        CFRelease(_outTextureCache);
    }
    _outTextureCache = nil;
    _renderTarget = nil;
    _inTexture = nil;
    _outTexture = nil;
}

-(void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    NSLog(@"Deallocated renderer %lld", _textureId);
    if (_renderTarget)
    {
        CVBufferRelease(_renderTarget);
    }
    if (_outTextureCache) {
        CFRelease(_outTextureCache);
    }
}

- (CVPixelBufferRef)copyPixelBuffer {
    if(_renderTarget){
        CVBufferRetain(_renderTarget);
        return _renderTarget;
    }
    return nil;
}


- (void)snapshotWithResult:(FlutterResult)result {
    __weak FlutterRTCVideoRenderer *weakSelf = self;
    dispatch_async(_videoQueue, ^{
        FlutterRTCVideoRenderer *strongSelf = weakSelf;
        NSData *data = [strongSelf blurSnapshot];
        if (data) {
            result([FlutterStandardTypedData typedDataWithBytes:data]);
        } else {
            result(nil);
        }
    });
}

- (NSData *)blurSnapshot {
    if (CGSizeEqualToSize(_frameSize, CGSizeZero)) {
        NSLog(@"INVALID FRAME BUFFER RETURNING");
        return nil;
    }
    [self.rendererColorSwizzle drawFrame:_inTexture outTexture:_outTexture width:_frameSize.width height:_frameSize.height cropWidth:_frameSize.width cropHeight:_frameSize.height cropX:0 cropY:0 rotation:kGPUImageNoRotation];
    [self.gaussBlur blur:_outTexture];
    if (!_renderTarget) {
        return nil;
    }
    
    if (@available(iOS 11.0, *)) {
        CIImage *image = [[CIImage alloc] initWithCVPixelBuffer:_renderTarget];
        CIContext * context = [[CIContext alloc] init];
        //image = [image imageByApplyingGaussianBlurWithSigma:40];
        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        //CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceGray();
        NSData *data = [context PNGRepresentationOfImage:image format:kCIFormatBGRA8 colorSpace:colorSpace options:@{}];
        CGColorSpaceRelease(colorSpace);
        return data;
    } else {
        __weak FlutterRTCVideoRenderer *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            FlutterRTCVideoRenderer *strongSelf = weakSelf;
            [strongSelf.registry textureFrameAvailable:strongSelf.textureId];
        });
    }
    return nil;
}

-(void)dispose{
    __weak FlutterRTCVideoRenderer *weakSelf = self;
    dispatch_async(_videoQueue, ^{
        FlutterRTCVideoRenderer *strongSelf = weakSelf;
        [strongSelf->_registry unregisterTexture:strongSelf->_textureId];
        [strongSelf teardownGL];
        [strongSelf->_eventChannel setStreamHandler:nil];
        strongSelf->_eventChannel = nil;
        strongSelf.videoFrame = nil;
        [strongSelf->_frameListeners removeAllObjects];
    });
}

- (void)setVideoTrack:(RTCVideoTrack *)videoTrack {
    RTCVideoTrack *oldValue = self.videoTrack;
    
    if (oldValue != videoTrack) {
        if (oldValue) {
            // NSLog(@"Remove old video track for : %lld", _textureId);
            [oldValue removeRenderer:self];
        }
        _videoTrack = videoTrack;
        if (videoTrack) {
            RTCVideoSource *source = videoTrack.source;
            if (source.capturer) {
                _usingFrontCamera = source.capturer.facing;
                _mirror = _usingFrontCamera;
                NSLog(@"has capturer");
            }
            [videoTrack addRenderer:self];
        }
    }
}

- (void)setMirror:(BOOL)mirror{
}

- (void)setBlur:(BOOL)blur{
    __weak FlutterRTCVideoRenderer *weakSelf = self;
    dispatch_async(_videoQueue, ^{
        FlutterRTCVideoRenderer *strongSelf = weakSelf;
        if (blur == strongSelf->_blur) {
            return;
        }
        strongSelf->_blur = blur;
    });
}


#pragma mark - RTCVideoRenderer methods
- (void)renderFrame:(nullable RTCVideoFrame *)frame{
    // NSLog(@"received frame size width %f", _frameSize.width);
    __weak FlutterRTCVideoRenderer *weakSelf = self;
    dispatch_async(_videoQueue, ^{
        FlutterRTCVideoRenderer *strongSelf = weakSelf;
        strongSelf.videoFrame = frame;
        [strongSelf processFrame];
    });
}

- (void)processFrame{
    RTCVideoFrame *frame = self.videoFrame;
    if (!frame || frame.timeStampNs == _lastDrawnFrameTimeStampNs) {
        NSLog(@"returning same frame");
        return;
    }
    if (!(_outTexture || _inTexture)) {
        return;
    }
    __weak FlutterRTCVideoRenderer *weakSelf = self;
    if(_renderSize.width != frame.width || _renderSize.height != frame.height){
        dispatch_async(dispatch_get_main_queue(), ^{
            FlutterRTCVideoRenderer *strongSelf = weakSelf;
            if(strongSelf.eventSink){
                strongSelf.eventSink(@{
                    @"event" : @"didTextureChangeVideoSize",
                    @"id": @(strongSelf.textureId),
                    @"width": @(frame.width),
                    @"height": @(frame.height),
                });
            }
        });
        _renderSize = CGSizeMake(frame.width, frame.height);
    }
    if(frame.rotation != _rotation){
        NSLog(@"Frame rotation changed: %ld", (long)frame.rotation);
        dispatch_async(dispatch_get_main_queue(), ^{
            FlutterRTCVideoRenderer *strongSelf = weakSelf;
            if(strongSelf.eventSink){
                strongSelf.eventSink(@{
                    @"event" : @"didTextureChangeRotation",
                    @"id": @(strongSelf.textureId),
                    @"rotation": @(frame.rotation),
                });
            }
        });
        _rotation = frame.rotation;
    }
    
    if (CGSizeEqualToSize(_frameSize, CGSizeZero)) {
        NSLog(@"Dropping frame, invalid frame size %@", _frameSize);
        return;
    }
    
    FlutterMTLRenderer *renderer;
    if ([frame.buffer isKindOfClass:[RTCCVPixelBuffer class]]) {
        RTCCVPixelBuffer *buffer = (RTCCVPixelBuffer*)frame.buffer;
        const OSType pixelFormat = CVPixelBufferGetPixelFormatType(buffer.pixelBuffer);
        if (pixelFormat == kCVPixelFormatType_32BGRA || pixelFormat == kCVPixelFormatType_32ARGB) {
            if (!self.rendererRGB) {
                self.rendererRGB = [FlutterRTCVideoRenderer createRGBRenderer:_device];
            }
            renderer = self.rendererRGB;
        } else {
            if (!self.rendererNV12) {
                self.rendererNV12 = [FlutterRTCVideoRenderer createNV12Renderer:_device];
            }
            renderer = self.rendererNV12;
        }
    } else {
        if (!self.rendererI420) {
            self.rendererI420 = [FlutterRTCVideoRenderer createI420Renderer:_device];
        }
        renderer = self.rendererI420;
    }
    
    // renderer.rotationOverride = self.rotationOverride;
    [renderer drawFrame:frame inTexture:_inTexture rotation:[self rtcRotationToGPURotation:_rotation]];
    if (!self.rendererColorSwizzle) {
        self.rendererColorSwizzle = [FlutterRTCVideoRenderer createColorSwizzleThroughRenderer:_device];
    }
    [self.rendererColorSwizzle drawFrame:_inTexture outTexture:_outTexture width:_frameSize.width height:_frameSize.height cropWidth:_frameSize.width cropHeight:_frameSize.height cropX:0 cropY:0 rotation:kGPUImageNoRotation];
    if (self.blur) {
        [self.gaussBlur blur:_outTexture];
    }
    //Notify the Flutter new pixelBufferRef to be ready.
    self.videoFrame = nil;
    frame = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        FlutterRTCVideoRenderer *strongSelf = weakSelf;
        [strongSelf.registry textureFrameAvailable:strongSelf.textureId];
    });
    [self notifyListeners];
}

/**
 * Sets the size of the video frame to render.
 *
 * @param size The size of the video frame to render.
 */
- (void)setSize:(CGSize)size {
    __weak FlutterRTCVideoRenderer *weakSelf = self;
    dispatch_async(_videoQueue, ^{
        FlutterRTCVideoRenderer *strongSelf = weakSelf;
        if((size.width != strongSelf->_frameSize.width || size.height != strongSelf->_frameSize.height))
        {
            strongSelf->_frameSize = size;
            [self destroyDataFBO];
            [self createDataFBO];
        }
    });
}

- (void)teardownGL {
    self.videoFrame = nil;
    [self destroyDataFBO];
}


- (void)setMute:(BOOL)mute{
    __weak FlutterRTCVideoRenderer *weakSelf = self;
    dispatch_async(_videoQueue, ^{
        FlutterRTCVideoRenderer *strongSelf = weakSelf;
        if (mute == strongSelf->_mute) {
            return;
        }
        strongSelf->_mute = mute;
        strongSelf->_blur = mute;
    });
}

#pragma mark - FlutterStreamHandler methods

- (FlutterError* _Nullable)onCancelWithArguments:(id _Nullable)arguments {
    _eventSink = nil;
    return nil;
}

- (FlutterError* _Nullable)onListenWithArguments:(id _Nullable)arguments
                                       eventSink:(nonnull FlutterEventSink)sink {
    _eventSink = sink;
    return nil;
}

-(GPUImageRotationMode)rtcRotationToGPURotation:(RTCVideoRotation )rotation{
    return [FlutterGLFilter rtcRotationToGPURotation:rotation mirror:_mirror usingFrontCamera:_usingFrontCamera];
}

#pragma mark - CameraSwitchObserver methods

- (void)willSwitchCamera:(bool)isFacing trackId: (NSString*)trackid {
    if ([trackid isEqualToString:self.videoTrack.trackId]) {
        [self.videoTrack removeRenderer:(id<RTCVideoRenderer>)self];
    }
}

- (void)didSwitchCamera:(bool)isFacing trackId: (NSString*)trackid {
    if ([trackid isEqualToString:self.videoTrack.trackId]) {
        _mirror = isFacing;
        _usingFrontCamera = isFacing;
        [self.videoTrack addRenderer:self];
    }
}

- (void)didFailSwitch:(NSString*)trackid {
    if ([trackid isEqualToString:self.videoTrack.trackId]) {
        [self.videoTrack addRenderer:(id<RTCVideoRenderer>)self];
    }
}

-(void)addFrameListener:(id<FrameListener>)frameListener {
    __weak FlutterRTCVideoRenderer *weakSelf = self;
    dispatch_async(_videoQueue, ^{
        FlutterRTCVideoRenderer *strongSelf = weakSelf;
        [strongSelf->_frameListeners addObject:frameListener];
    });
}

-(void)removeFrameListener:(id<FrameListener>)frameListener {
    __weak FlutterRTCVideoRenderer *weakSelf = self;
    dispatch_async(_videoQueue, ^{
        FlutterRTCVideoRenderer *strongSelf = weakSelf;
        NSUInteger index = [strongSelf->_frameListeners indexOfObjectIdenticalTo:frameListener];
        if (index != NSNotFound) {
            [strongSelf->_frameListeners removeObjectAtIndex:index];
        }
    });
}

-(void)notifyListeners {
    NSMutableArray *discardedItems = [NSMutableArray array];
    for (id<FrameListener> listener in _frameListeners) {
        [discardedItems addObject:listener];
    }
    [_frameListeners removeObjectsInArray:discardedItems];
    for (id<FrameListener> listener in discardedItems) {
        if (listener.hasFrameBuffer) {
            [listener drawWithTexture:_inTexture frameSize:_frameSize rotation:kGPUImageNoRotation];
        } else {
            // [listener onFrame:self.videoFilter.renderTarget];
        }
    }
}

@end

@implementation FlutterWebRTCPlugin (FlutterRTCVideoRenderer)

- (FlutterRTCVideoRenderer *)createWithTextureRegistry:(id<FlutterTextureRegistry>)registry{
    return [[FlutterRTCVideoRenderer alloc] initWithTextureRegistry:registry messenger:self.messenger];
}

-(void)rendererSetSrcObject:(FlutterRTCVideoRenderer*)renderer stream:(RTCVideoTrack*)videoTrack{
    RTCVideoTrack *oldValue = renderer.videoTrack;
    if (oldValue != videoTrack) {
        if (oldValue) {
            [self removeCameraListener:renderer];
        }
        if (videoTrack) {
            [self addCameraListener:renderer];
        }
    }
    renderer.videoTrack = videoTrack;
}
@end

