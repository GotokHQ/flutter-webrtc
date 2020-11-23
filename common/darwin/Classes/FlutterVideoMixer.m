#import "FlutterVideoMixer.h"
#import "SamplesInterceptorDelegate.h"
#import "FlutterVideoMixerRenderer.h"
#import "MTLRGBRenderer.h"
#import "MTLNV12Renderer.h"
#import "MTLI420Renderer.h"
#import "MTLColorSwizzleRenderer.h"
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>

static const int DEFAULT_FPS = 24 ;

#define TIME_UNIT 1000

#define NOW (CACurrentMediaTime()*TIME_UNIT)

@interface FlutterVideoMixer()
    @property(nonatomic) MTLColorSwizzleRenderer *renderer;
@end


@implementation FlutterVideoMixer{
    BOOL _discont;
    CMTime _startTime, _previousFrameTime, _previousAudioTime;
    CMTime _offsetTime;
    RTCVideoTrack *_videoTrack;
    CVPixelBufferRef _renderTarget;
    RTCVideoRotation _rotation;
    CGSize _size;
    int64_t _lastDrawnFrameTimeStampNs;
    dispatch_queue_t _videoQueue;
    CGSize _frameSize;
    dispatch_source_t _videoTimer;
    NSMutableArray<FlutterVideoMixerRenderer *> *_renderers;
    BOOL _running;
    id<MTLDevice> _device;
    CVMetalTextureCacheRef _renderTextureCache;
    id<MTLTexture> _texture;
}

-(instancetype)initWithDelegate:(__weak id<SamplesInterceptorDelegate>)delegate size:(CGSize)size framesPerSecond:(int)fps {
    if (self = [super init]) {
        _fps = fps ? fps : DEFAULT_FPS;
        _size = size;
        _discont = NO;
        _previousFrameTime = kCMTimeNegativeInfinity;
        _previousAudioTime = kCMTimeNegativeInfinity;
        _offsetTime = kCMTimeZero;
        _frameSize = CGSizeZero;
        _size = size;
        _delegate = delegate;
        _renderers = [[NSMutableArray alloc] init];
        _videoQueue = dispatch_queue_create("FlutterWebRTC/FlutterVideoMixer", DISPATCH_QUEUE_SERIAL);
    }
    [self initGL];
    return self;
}

- (void)initGL {
    _device = MTLCreateSystemDefaultDevice();
    _renderer = [[MTLColorSwizzleRenderer alloc] initWithDevice:_device];
    [self createDataFBO];
}

#pragma mark -
#pragma mark Frame rendering

- (BOOL)initializeTextureCache {
    CVReturn status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, _device,
                                       nil, &_renderTextureCache);
    if (status != kCVReturnSuccess) {
        NSLog(@"Metal: Failed to initialize metal texture cache. Return status is %d", status);
        return NO;
    }
    return YES;
}


- (void)createDataFBO {
    if (!_renderTextureCache) {
        [self initializeTextureCache];
    }
    CVMetalTextureRef textureOut;
    CFDictionaryRef empty; // empty value for attr value.
    CFMutableDictionaryRef attrs;
    empty = CFDictionaryCreate(kCFAllocatorDefault, NULL, NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks); // our empty IOSurface properties dictionary
    attrs = CFDictionaryCreateMutable(kCFAllocatorDefault, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(attrs, kCVPixelBufferIOSurfacePropertiesKey, empty);
    
    CVReturn err = CVPixelBufferCreate(kCFAllocatorDefault, (int)_size.width, (int)_size.height, kCVPixelFormatType_32BGRA, attrs, &_renderTarget);
    if (err)
    {
        NSLog(@"FBO size: %f, %f", _size.width, _size.height);
        NSAssert(NO, @"Error at CVPixelBufferCreate %d", err);
    }
    err = CVMetalTextureCacheCreateTextureFromImage(
                                                                kCFAllocatorDefault, _renderTextureCache, _renderTarget, nil, MTLPixelFormatBGRA8Unorm,
                                                                _size.width, _size.height, 0, &textureOut);
    
    if (err)
    {
        NSAssert(NO, @"Error at CVOpenGLESTextureCacheCreateTextureFromImage %d", err);
    }
    
    CFRelease(attrs);
    CFRelease(empty);
    _texture = CVMetalTextureGetTexture(textureOut);
    CVBufferRelease(textureOut);
    NSLog(@"created FBO with size: %f, %f", _size.width, _size.height);
}

- (void)destroyDataFBO;
{
    if (_renderTarget)
    {
        CVBufferRelease(_renderTarget);
    }
    if (_renderTextureCache) {
        CFRelease(_renderTextureCache);
    }
    _renderTextureCache = nil;
    _renderTarget = nil;
    _texture = nil;
}

- (void)dealloc{
    [self destroyDataFBO];
    NSLog(@"flutter video mixer deallocated");
}

- (void)cleanup
{
    _running = NO;
    for (FlutterVideoMixerRenderer* videoRenderer in _renderers) {
        videoRenderer.track = nil;
    }
    [_renderers removeAllObjects];
    if(_videoTimer) {
        dispatch_source_cancel(_videoTimer);
        _videoTimer = nil;
    }
    self.delegate = nil;
    _videoQueue = nil;
    [self destroyDataFBO];
}

-(void)onAddVideoTrack:(RTCVideoTrack *)track isRemote:(BOOL)remote label:(NSString*)label{
    __weak FlutterVideoMixer *weakSelf = self;
    dispatch_async(_videoQueue, ^{
        FlutterVideoMixer *strongSelf = weakSelf;
        FlutterVideoMixerRenderer* videoRenderer = [[FlutterVideoMixerRenderer alloc]  initWithdDevice:strongSelf->_device track:track isRemote:remote label:label];
        NSUInteger index = [strongSelf->_renderers indexOfObjectIdenticalTo:videoRenderer];
        NSAssert(index == NSNotFound,@"|onAddVideoTrack| A renderer for that track already exist");
        [strongSelf->_renderers addObject:videoRenderer];
        [self layoutVertices];
    });
}

-(void)onRemoveVideoTrack:(RTCVideoTrack *)track isRemote:(BOOL)remote label:(NSString*)label {
    __weak FlutterVideoMixer *weakSelf = self;
    dispatch_async(_videoQueue, ^{
        FlutterVideoMixer *strongSelf = weakSelf;
        FlutterVideoMixerRenderer* videoRenderer = [[FlutterVideoMixerRenderer alloc] initWithdDevice:strongSelf->_device track:track isRemote:remote label:label];
        NSUInteger index = [strongSelf->_renderers indexOfObjectIdenticalTo:videoRenderer];
        NSAssert(index != NSNotFound,
                 @"|onRemoveVideoTrack| called on unexpected RTCVideoTrack");
        if (index != NSNotFound) {
            videoRenderer = [strongSelf->_renderers objectAtIndex:index];
            videoRenderer.track = nil;
            [strongSelf->_renderers removeObjectAtIndex:index];
        }
        [self layoutVertices];
    });
}

-(void)layoutVertices{
    NSLog(@"LAYOUT VERTICES %lu",(unsigned long)_renderers.count);
    if(_renderers.count == 1){
        FlutterVideoMixerRenderer * renderer = _renderers[0];
        
        CGRect bounds = CGRectMake(0,0, _size.width, _size.height);
        renderer.bounds = bounds;
        
        NSLog(@"size of renderer at pos[%d] is  %@",0,NSStringFromCGSize(bounds.size));
        return;
    }else{
        CGFloat width = _size.width/_renderers.count;
        CGFloat xPos = 0;
        CGFloat yPos = 0;
        for(int i=0; i < _renderers.count; i++){
            FlutterVideoMixerRenderer * renderer = _renderers[i];
            CGRect bounds = CGRectMake(xPos,yPos, width, _size.height);
            NSLog(@"size of renderer at pos[%d] is  %@",i,NSStringFromCGSize(bounds.size));
            NSLog(@"X of renderer at pos[%d] is  %f",i,xPos);
            NSLog(@"Y of renderer at pos[%d] is  %f",i,yPos);
            renderer.bounds = bounds;
            xPos += width;
        }
    }
    if (_texture){
        [self destroyDataFBO];
        [self createDataFBO];
    }
}

-(void)startCaptureWithCompletion:(FlutterVideoMixerSuccessCallback)onComplete onError:(FlutterVideoMixerErrorCallback)onError;
{
    if (_running) {
        return;
    }
    __weak FlutterVideoMixer *weakSelf = self;
    dispatch_async(_videoQueue, ^{
        FlutterVideoMixer *strongSelf = weakSelf;
        [strongSelf startVideoCaptureFromDispatchSource];
        self->_running = YES;
        if(onComplete) {
            onComplete();
        }
        NSLog(@"START RECORD CAPTURE CALLED");
    });

}

-(void)startVideoCaptureFromDispatchSource;
{
    if(!_videoTimer){
        _videoTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, DISPATCH_TIMER_STRICT, _videoQueue);
    }
    
    Float64 interval = NSEC_PER_SEC / _fps;
    int64_t pts = lroundf(interval);
    //NSLog(@"INTERVAL TO WAIT IS %lld",_interval);
    dispatch_source_set_timer(_videoTimer, DISPATCH_TIME_NOW, pts, 0 );
    
    __weak FlutterVideoMixer *weakSelf = self;
    // Callback when timer is fired
    dispatch_source_set_event_handler(_videoTimer, ^{
        FlutterVideoMixer *strongSelf = weakSelf;
        [strongSelf captureFrame];
    });
    dispatch_resume(_videoTimer);
}


#pragma mark - Frame Grabber

- (void)captureFrame;
{
    //NSLog(@"captureFrameAtTime: %@", CFBridgingRelease(CMTimeCopyDescription(kCFAllocatorDefault, _startTime)));
    if (!_running)
    {
        return;
    }
    __weak FlutterVideoMixer *weakSelf = self;
    dispatch_async(_videoQueue, ^{
        FlutterVideoMixer *strongSelf = weakSelf;
        [strongSelf processFrames];
    });
}

-(void)processFrames{
    if (!_running)
    {
        return;
    }
    if (!_texture) {
        NSLog(@"no frame buffer created: returning");
        return;
    }
    BOOL hasRendered = NO;

    for (FlutterVideoMixerRenderer* renderer in _renderers)
    {
        if (renderer.firstFrameRendered) {
            hasRendered = YES;
            break;
        }
    }
    if (!hasRendered) {
        return;
    }
    [self.renderer drawFrame:_renderers outTexture:_texture];
    CVPixelBufferLockBaseAddress(_renderTarget, 0);
    NSTimeInterval timeStampSeconds = CACurrentMediaTime();
    int64_t timeStampNs = lroundf(timeStampSeconds * NSEC_PER_SEC);
    CMTime frameTime = CMTimeMake(timeStampNs, NSEC_PER_SEC);
    if (CMTIME_IS_INVALID(_startTime))
    {
        _startTime = frameTime;
        NSLog(@"Start Time from video is: %@", CFBridgingRelease(CMTimeCopyDescription(kCFAllocatorDefault, _startTime)));
    }
    [self.delegate didCaptureVideoSamples:_renderTarget atTime:frameTime rotation:RTCVideoRotation_0];
    CVPixelBufferUnlockBaseAddress(_renderTarget, 0);
}

- (void)stopCaptureWithCompletion:(FlutterVideoMixerSuccessCallback)onComplete onError:(FlutterVideoMixerErrorCallback)onError{
    if (!_running) {
        if (onError) {
            onError(@"error", @"Video is not recording!");
        }
        return;
    }
    __weak FlutterVideoMixer *weakSelf = self;
    dispatch_async(_videoQueue, ^{
        FlutterVideoMixer *strongSelf = weakSelf;
        [strongSelf cleanup];
        if (onComplete) {
            onComplete();
        }
    });
}

#pragma mark - CameraSwitchObserver methods

- (void)willSwitchCamera:(bool)isFacing trackId:(NSString*)trackid {
    __weak FlutterVideoMixer *weakSelf = self;
    dispatch_async(_videoQueue, ^{
        FlutterVideoMixer *strongSelf = weakSelf;
        FlutterVideoMixerRenderer* renderer = [strongSelf rendererForId:trackid];
        if (renderer) {
            renderer.mirror = isFacing;
            [renderer switchTrack:NO];
        }
    });
}

- (void)didSwitchCamera:(bool)isFacing trackId: (NSString*)trackid {
    __weak FlutterVideoMixer *weakSelf = self;
    dispatch_async(_videoQueue, ^{
        FlutterVideoMixer *strongSelf = weakSelf;
        FlutterVideoMixerRenderer* renderer = [strongSelf rendererForId:trackid];
        if (renderer) {
            renderer.mirror = isFacing;
            [renderer switchTrack:YES];
        }
    });
}

- (void)didFailSwitch:(NSString*)trackid {
    __weak FlutterVideoMixer *weakSelf = self;
    dispatch_async(_videoQueue, ^{
        FlutterVideoMixer *strongSelf = weakSelf;
        FlutterVideoMixerRenderer* renderer = [strongSelf rendererForId:trackid];
        if (renderer) {
            [renderer switchTrack:YES];
        }
    });
}

- (FlutterVideoMixerRenderer*)rendererForId:(NSString*)trackId
{
    for (FlutterVideoMixerRenderer *renderer in _renderers) {
        if ([renderer.track.trackId isEqualToString:trackId]) {
            return renderer;
        }
    }
    return nil;
}
@end
