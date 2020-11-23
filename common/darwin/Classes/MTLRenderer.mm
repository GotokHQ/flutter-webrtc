/*
 *  Copyright 2017 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#import "MTLRenderer.h"
#import <math.h>
// As defined in shaderSource.
static NSString *const vertexFunctionName = @"vertexPassthrough";
static NSString *const fragmentFunctionName = @"fragmentColorConversion";

static NSString *const pipelineDescriptorLabel = @"RTCPipeline";
static NSString *const commandBufferLabel = @"RTCCommandBuffer";
static NSString *const renderEncoderLabel = @"RTCEncoder";
static NSString *const renderEncoderDebugGroup = @"RTCDrawFrame";

// Computes the texture coordinates given rotation and cropping.
static inline void getCubeVertexData(int cropX,
                                     int cropY,
                                     int cropWidth,
                                     int cropHeight,
                                     size_t frameWidth,
                                     size_t frameHeight,
                                     GPUImageRotationMode rotation,
                                     float *buffer) {
    // The computed values are the adjusted texture coordinates, in [0..1].
    // For the left and top, 0.0 means no cropping and e.g. 0.2 means we're skipping 20% of the
    // left/top edge.
    // For the right and bottom, 1.0 means no cropping and e.g. 0.8 means we're skipping 20% of the
    // right/bottom edge (i.e. render up to 80% of the width/height).
    float cropLeft = cropX / (float)frameWidth;
    float cropRight = (cropX + cropWidth) / (float)frameWidth;
    float cropTop = cropY / (float)frameHeight;
    float cropBottom = (cropY + cropHeight) / (float)frameHeight;
    
    [FlutterGLFilter textureCoordinatesForMetalRotation:rotation cropLeft:cropLeft cropRight:cropRight cropTop:cropTop cropBottom:cropBottom buffer:buffer];
}


void getCubeVertexDataWithObjectFit(float frameWidth, float frameHeight, GPUImageRotationMode rotation, RTCVideoViewObjectFit objectFit, float displayWidth, float displayHeight, float *buffer) {
    
    float heightScaling = 1.0, widthScaling =  1.0;
    CGSize size = CGSizeMake(frameWidth, frameHeight);
    CGRect display = CGRectMake(0, 0, displayWidth, displayHeight);
    CGSize outputSize = display.size;
    if (!CGRectEqualToRect(display, CGRectZero)) {
        CGRect insetRect = AVMakeRectWithAspectRatioInsideRect(size, display);

        switch(objectFit)
        {
            case RTCVideoViewObjectFitCover:
            {
                //            CGFloat widthHolder = insetRect.size.width / currentViewSize.width;
                widthScaling = outputSize.height / insetRect.size.height;
                heightScaling = outputSize.width / insetRect.size.width;
            }; break;
            case RTCVideoViewObjectFitContain:
            default:
            {
                widthScaling = insetRect.size.width / outputSize.width;
                heightScaling = insetRect.size.height / outputSize.height;
            };
        }

    }
    [FlutterGLFilter textureCoordinatesForMetalRotation:rotation widthScaling:widthScaling heightScaling:heightScaling buffer:buffer];
}

// The max number of command buffers in flight (submitted to GPU).
// For now setting it up to 1.
// In future we might use triple buffering method if it improves performance.
static const NSInteger kMaxInflightBuffers = 1;

@implementation FlutterMTLRenderer {
    
    // Controller.
    dispatch_semaphore_t _inflight_semaphore;
    
    // Renderer.
    id<MTLDevice> _device;
    id<MTLCommandQueue> _commandQueue;
    id<MTLLibrary> _defaultLibrary;
    id<MTLRenderPipelineState> _pipelineState;
    
    // Buffers.
    id<MTLBuffer> _vertexBuffer;
    
    // Values affecting the vertex buffer. Stored for comparison to avoid unnecessary recreation.
    int _oldFrameWidth;
    int _oldFrameHeight;
    int _oldCropWidth;
    int _oldCropHeight;
    int _oldCropX;
    int _oldCropY;
    RTCVideoViewObjectFit _oldObjectFit;
    int _oldDisplayWidth;
    int _oldDisplayHeight;
    GPUImageRotationMode _oldRotation;
    id<MTLTexture> _texture;
    MTLRenderPassDescriptor *_renderPassDescriptor;
}

@synthesize rotationOverride = _rotationOverride;

- (instancetype)initWithDevice:(id<MTLDevice>)device{
    MTLRenderPassDescriptor *renderPassDescriptor = [MTLRenderPassDescriptor new];
    renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    renderPassDescriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
    renderPassDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
    return [self initWithDevice:device descriptor:renderPassDescriptor];
}


- (instancetype)initWithDevice:(id<MTLDevice>)device descriptor:(MTLRenderPassDescriptor*)descriptor{
    if (self = [super init]) {
        _device = device;
        _inflight_semaphore = dispatch_semaphore_create(kMaxInflightBuffers);
        [self setupMetal];
        _renderPassDescriptor = descriptor;
    }
    return self;
}

#pragma mark - Inheritance

- (id<MTLDevice>)currentMetalDevice {
    return _device;
}

- (NSString *)shaderSource {
    return @"";
}

- (void)uploadTexturesToRenderEncoder:(id<MTLRenderCommandEncoder>)renderEncoder {
}


- (void)getWidth:(int *)width
          height:(int *)height
       cropWidth:(int *)cropWidth
      cropHeight:(int *)cropHeight
           cropX:(int *)cropX
           cropY:(int *)cropY
         ofFrame:(nonnull RTCVideoFrame *)frame {
}

- (BOOL)setupTexturesForFrame:(nonnull RTCVideoFrame *)frame rotation:(GPUImageRotationMode)rotationValue{
    // Apply rotation override if set.
    GPUImageRotationMode rotation;
    NSValue *rotationOverride = self.rotationOverride;
    if (rotationOverride) {
#if defined(__IPHONE_11_0) && defined(__IPHONE_OS_VERSION_MAX_ALLOWED) && \
(__IPHONE_OS_VERSION_MAX_ALLOWED >= __IPHONE_11_0)
        if (@available(iOS 11, *)) {
            [rotationOverride getValue:&rotation size:sizeof(rotation)];
        } else
#endif
        {
            [rotationOverride getValue:&rotation];
        }
    } else {
        rotation = rotationValue;
    }
    
    int frameWidth, frameHeight, cropWidth, cropHeight, cropX, cropY;
    [self getWidth:&frameWidth
            height:&frameHeight
         cropWidth:&cropWidth
        cropHeight:&cropHeight
             cropX:&cropX
             cropY:&cropY
           ofFrame:frame];
    
    // Recompute the texture cropping and recreate vertexBuffer if necessary.
    if (cropX != _oldCropX || cropY != _oldCropY || cropWidth != _oldCropWidth ||
        cropHeight != _oldCropHeight || rotation != _oldRotation || frameWidth != _oldFrameWidth ||
        frameHeight != _oldFrameHeight) {
        getCubeVertexData(cropX,
                          cropY,
                          cropWidth,
                          cropHeight,
                          frameWidth,
                          frameHeight,
                          rotation,
                          (float *)_vertexBuffer.contents);
        _oldCropX = cropX;
        _oldCropY = cropY;
        _oldCropWidth = cropWidth;
        _oldCropHeight = cropHeight;
        _oldRotation = rotation;
        _oldFrameWidth = frameWidth;
        _oldFrameHeight = frameHeight;
    }
    
    return YES;
}

- (BOOL)setupTexturesForWidth:(int)width
                       height:(int)height
                    cropWidth:(int)cropWidth
                   cropHeight:(int)cropHeight
                        cropX:(int)cropX
                        cropY:(int)cropY
                     rotation:(GPUImageRotationMode)rotationValue{
    // Apply rotation override if set.
    GPUImageRotationMode rotation;
    NSValue *rotationOverride = self.rotationOverride;
    if (rotationOverride) {
#if defined(__IPHONE_11_0) && defined(__IPHONE_OS_VERSION_MAX_ALLOWED) && \
(__IPHONE_OS_VERSION_MAX_ALLOWED >= __IPHONE_11_0)
        if (@available(iOS 11, *)) {
            [rotationOverride getValue:&rotation size:sizeof(rotation)];
        } else
#endif
        {
            [rotationOverride getValue:&rotation];
        }
    } else {
        rotation = rotationValue;
    }
    
    
    // Recompute the texture cropping and recreate vertexBuffer if necessary.
    if (cropX != _oldCropX || cropY != _oldCropY || cropWidth != _oldCropWidth ||
        cropHeight != _oldCropHeight || rotation != _oldRotation || width != _oldFrameWidth ||
        height != _oldFrameHeight) {
        getCubeVertexData(cropX,
                          cropY,
                          cropWidth,
                          cropHeight,
                          width,
                          height,
                          rotation,
                          (float *)_vertexBuffer.contents);
        _oldCropX = cropX;
        _oldCropY = cropY;
        _oldCropWidth = cropWidth;
        _oldCropHeight = cropHeight;
        _oldRotation = rotation;
        _oldFrameWidth = width;
        _oldFrameHeight = height;
    }
    
    return YES;
}

- (BOOL)setupTexturesForFrame:(nonnull RTCVideoFrame *)frame rotation:(GPUImageRotationMode)rotationValue fit:(RTCVideoViewObjectFit)objectFit displayWidth:(int)displayWidth displayHeight:(int)displayHeight {
    // Apply rotation override if set.
    GPUImageRotationMode rotation;
    NSValue *rotationOverride = self.rotationOverride;
    if (rotationOverride) {
#if defined(__IPHONE_11_0) && defined(__IPHONE_OS_VERSION_MAX_ALLOWED) && \
(__IPHONE_OS_VERSION_MAX_ALLOWED >= __IPHONE_11_0)
        if (@available(iOS 11, *)) {
            [rotationOverride getValue:&rotation size:sizeof(rotation)];
        } else
#endif
        {
            [rotationOverride getValue:&rotation];
        }
    } else {
        rotation = rotationValue;
    }
    int frameWidth = frame.width;
    int frameHeight = frame.height;
    int renderWidth = displayWidth;
    int renderHeight = displayHeight;
    if (frame.rotation == RTCVideoRotation_90 || frame.rotation == RTCVideoRotation_270) {
        frameWidth = frame.height;
        frameHeight = frame.width;
    }
//    if (frame.rotation == RTCVideoRotation_90 || frame.rotation == RTCVideoRotation_270) {
//        renderWidth = displayHeight;
//        renderHeight = displayWidth;
//    }
    // Recompute the texture cropping and recreate vertexBuffer if necessary.
    if (rotation != _oldRotation || frameWidth != _oldFrameWidth ||
        frameHeight != _oldFrameHeight || objectFit != _oldObjectFit || displayWidth != _oldDisplayWidth || displayHeight != _oldDisplayHeight) {
        getCubeVertexDataWithObjectFit(
                                       frameWidth,
                                       frameHeight,
                                       rotation,
                                       objectFit,
                                       renderWidth,
                                       renderHeight,
                                       (float *)_vertexBuffer.contents);
        _oldRotation = rotation;
        _oldFrameWidth = frameWidth;
        _oldFrameHeight = frameHeight;
        _oldObjectFit = objectFit;
        _oldDisplayWidth = displayWidth;
        _oldDisplayHeight = displayHeight;
    }
    return YES;
}

- (BOOL)setupTexturesForWidth:(int)width height:(int)height rotation:(GPUImageRotationMode)rotationValue fit:(RTCVideoViewObjectFit)objectFit displayWidth:(int)displayWidth displayHeight:(int) displayHeight {
    // Apply rotation override if set.
    GPUImageRotationMode rotation;
    NSValue *rotationOverride = self.rotationOverride;
    if (rotationOverride) {
#if defined(__IPHONE_11_0) && defined(__IPHONE_OS_VERSION_MAX_ALLOWED) && \
(__IPHONE_OS_VERSION_MAX_ALLOWED >= __IPHONE_11_0)
        if (@available(iOS 11, *)) {
            [rotationOverride getValue:&rotation size:sizeof(rotation)];
        } else
#endif
        {
            [rotationOverride getValue:&rotation];
        }
    } else {
        rotation = rotationValue;
    }
    
    // Recompute the texture cropping and recreate vertexBuffer if necessary.
    if (rotation != _oldRotation || width != _oldFrameWidth ||
        height != _oldFrameHeight || objectFit != _oldObjectFit || displayWidth != _oldDisplayWidth || displayHeight != _oldDisplayHeight) {
        getCubeVertexDataWithObjectFit(
                                       width,
                                       height,
                                       rotation,
                                       objectFit,
                                       displayWidth,
                                       displayHeight,
                                       (float *)_vertexBuffer.contents);
        _oldRotation = rotation;
        _oldFrameWidth = width;
        _oldFrameHeight = height;
        _oldObjectFit = objectFit;
        _oldDisplayWidth = displayWidth;
        _oldDisplayHeight = displayHeight;
    }
    
    return YES;
}

#pragma mark - GPU methods

- (BOOL)setupMetal {
    
    // Create a new command queue.
    _commandQueue = [_device newCommandQueue];
    
    // Load metal library from source.
    NSError *libraryError = nil;
    NSString *shaderSource = [self shaderSource];
    
    id<MTLLibrary> sourceLibrary =
    [_device newLibraryWithSource:shaderSource options:NULL error:&libraryError];
    
    if (libraryError) {
        NSLog(@"Metal: Library with source failed\n%@", libraryError);
        return NO;
    }
    
    if (!sourceLibrary) {
        NSLog(@"Metal: Failed to load library. %@", libraryError);
        return NO;
    }
    _defaultLibrary = sourceLibrary;
    
    [self loadAssets];
    
    float vertexBufferArray[16] = {0};
    _vertexBuffer = [_device newBufferWithBytes:vertexBufferArray
                                         length:sizeof(vertexBufferArray)
                                        options:MTLResourceCPUCacheModeWriteCombined];
    return YES;
}

- (void)loadAssets {
    id<MTLFunction> vertexFunction = [_defaultLibrary newFunctionWithName:vertexFunctionName];
    id<MTLFunction> fragmentFunction = [_defaultLibrary newFunctionWithName:fragmentFunctionName];
    
    MTLRenderPipelineDescriptor *pipelineDescriptor = [[MTLRenderPipelineDescriptor alloc] init];
    pipelineDescriptor.label = pipelineDescriptorLabel;
    pipelineDescriptor.vertexFunction = vertexFunction;
    pipelineDescriptor.fragmentFunction = fragmentFunction;
    pipelineDescriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    pipelineDescriptor.depthAttachmentPixelFormat = MTLPixelFormatInvalid;
    NSError *error = nil;
    _pipelineState = [_device newRenderPipelineStateWithDescriptor:pipelineDescriptor error:&error];
    
    if (!_pipelineState) {
        NSLog(@"Metal: Failed to create pipeline state. %@", error);
    }
}

- (void)renderInTexture:(id<MTLTexture>)texture {
    id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    commandBuffer.label = commandBufferLabel;
    
    __block dispatch_semaphore_t block_semaphore = _inflight_semaphore;
    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> _Nonnull) {
        // GPU work completed.
        dispatch_semaphore_signal(block_semaphore);
    }];
    
    if (_renderPassDescriptor) {
        _renderPassDescriptor.colorAttachments[0].texture = texture;// Valid drawable
        id<MTLRenderCommandEncoder> renderEncoder =
        [commandBuffer renderCommandEncoderWithDescriptor:_renderPassDescriptor];
        renderEncoder.label = renderEncoderLabel;
        
        // Set context state.
        [renderEncoder pushDebugGroup:renderEncoderDebugGroup];
        [renderEncoder setRenderPipelineState:_pipelineState];
        [renderEncoder setVertexBuffer:_vertexBuffer offset:0 atIndex:0];
        [self uploadTexturesToRenderEncoder:renderEncoder];
        
        [renderEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                          vertexStart:0
                          vertexCount:4
                        instanceCount:1];
        [renderEncoder popDebugGroup];
        [renderEncoder endEncoding];
        
    }
    
    // CPU work is completed, GPU work can be started.
    [commandBuffer commit];
}

- (void)renderFromTexture:(id<MTLTexture>)inTexture to:(id<MTLTexture>)outTexture {
    id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    commandBuffer.label = commandBufferLabel;
    
    __block dispatch_semaphore_t block_semaphore = _inflight_semaphore;
    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> _Nonnull) {
        // GPU work completed.
        dispatch_semaphore_signal(block_semaphore);
    }];
    
    if (_renderPassDescriptor) {
        _renderPassDescriptor.colorAttachments[0].texture = outTexture;// Valid drawable
        id<MTLRenderCommandEncoder> renderEncoder =
        [commandBuffer renderCommandEncoderWithDescriptor:_renderPassDescriptor];
        renderEncoder.label = renderEncoderLabel;
        
        // Set context state.
        [renderEncoder pushDebugGroup:renderEncoderDebugGroup];
        [renderEncoder setRenderPipelineState:_pipelineState];
        [renderEncoder setVertexBuffer:_vertexBuffer offset:0 atIndex:0];
        [renderEncoder setFragmentTexture:inTexture atIndex:0];
        
        [renderEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                          vertexStart:0
                          vertexCount:4
                        instanceCount:1];
        [renderEncoder popDebugGroup];
        [renderEncoder endEncoding];
        
    }
    
    // CPU work is completed, GPU work can be started.
    [commandBuffer commit];
}

- (void)renderFromTexture:(id<MTLTexture>)inTexture to:(id<MTLTexture>)outTexture viewPort:(MTLViewport)viewPort scissorRect:(MTLScissorRect)scissorRect{
    id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    commandBuffer.label = commandBufferLabel;
    
    __block dispatch_semaphore_t block_semaphore = _inflight_semaphore;
    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> _Nonnull) {
        // GPU work completed.
        dispatch_semaphore_signal(block_semaphore);
    }];
    
    if (_renderPassDescriptor) {
        _renderPassDescriptor.colorAttachments[0].texture = outTexture;// Valid drawable
        id<MTLRenderCommandEncoder> renderEncoder =
        [commandBuffer renderCommandEncoderWithDescriptor:_renderPassDescriptor];
        renderEncoder.label = renderEncoderLabel;
        
        // Set context state.
        [renderEncoder pushDebugGroup:renderEncoderDebugGroup];
        [renderEncoder setViewport:viewPort];
        [renderEncoder setScissorRect:scissorRect];
        [renderEncoder setRenderPipelineState:_pipelineState];
        [renderEncoder setVertexBuffer:_vertexBuffer offset:0 atIndex:0];
        [renderEncoder setFragmentTexture:inTexture atIndex:0];
        [renderEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                          vertexStart:0
                          vertexCount:4
                        instanceCount:1];
        [renderEncoder popDebugGroup];
        [renderEncoder endEncoding];
        
    }
    
    // CPU work is completed, GPU work can be started.
    [commandBuffer commit];
}

- (void)renderFromTextures:(NSArray<id<FlutterMTLTextureHolder>> *)inTextures to:(id<MTLTexture>)outTexture {
    id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    commandBuffer.label = commandBufferLabel;
    
    __block dispatch_semaphore_t block_semaphore = _inflight_semaphore;
    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> _Nonnull) {
        // GPU work completed.
        dispatch_semaphore_signal(block_semaphore);
    }];
    
    if (_renderPassDescriptor) {
        _renderPassDescriptor.colorAttachments[0].texture = outTexture;// Valid drawable
        id<MTLRenderCommandEncoder> renderEncoder =
        [commandBuffer renderCommandEncoderWithDescriptor:_renderPassDescriptor];
        renderEncoder.label = renderEncoderLabel;
        
        // Set context state.
        [renderEncoder pushDebugGroup:renderEncoderDebugGroup];
        
        for (id<FlutterMTLTextureHolder> textureHolder in inTextures)
        {
            MTLViewport viewPort = {textureHolder.bounds.origin.x, textureHolder.bounds.origin.y, textureHolder.bounds.size.width, textureHolder.bounds.size.height};
            MTLScissorRect scissor = {(NSUInteger)textureHolder.bounds.origin.x, (NSUInteger)textureHolder.bounds.origin.y, (NSUInteger)textureHolder.bounds.size.width, (NSUInteger)textureHolder.bounds.size.height} ;
            [renderEncoder setViewport:viewPort];
            [renderEncoder setScissorRect:scissor];
            [renderEncoder setRenderPipelineState:_pipelineState];
            [renderEncoder setVertexBuffer:textureHolder.vertexBuffer offset:0 atIndex:0];
            [renderEncoder setFragmentTexture:textureHolder.texture atIndex:0];
            [renderEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                              vertexStart:0
                              vertexCount:4
                            instanceCount:1];
        }
        [renderEncoder popDebugGroup];
        [renderEncoder endEncoding];
        
    }
    
    // CPU work is completed, GPU work can be started.
    [commandBuffer commit];
}
#pragma mark - RTCMTLRenderer

- (void)drawFrame:(RTCVideoFrame*)frame inTexture:(id<MTLTexture>)texture rotation:(GPUImageRotationMode)rotation{
    @autoreleasepool {
        // Wait until the inflight (curently sent to GPU) command buffer
        // has completed the GPU work.
        dispatch_semaphore_wait(_inflight_semaphore, DISPATCH_TIME_FOREVER);
        
        if ([self setupTexturesForFrame:frame rotation:rotation]) {
            [self renderInTexture:texture];
        } else {
            dispatch_semaphore_signal(_inflight_semaphore);
        }
    }
}

- (void)drawFrame:(id<MTLTexture>)inTexture
       outTexture:(id<MTLTexture>)outTexture
            width:(int)width
           height:(int)height
        cropWidth:(int)cropWidth
       cropHeight:(int)cropHeight
            cropX:(int)cropX
            cropY:(int)cropY
         rotation:(GPUImageRotationMode)rotation
{
    @autoreleasepool {
        // Wait until the inflight (curently sent to GPU) command buffer
        // has completed the GPU work.
        dispatch_semaphore_wait(_inflight_semaphore, DISPATCH_TIME_FOREVER);
        
        if ([self setupTexturesForWidth:width
                                 height:height
                              cropWidth:cropWidth
                             cropHeight:cropHeight
                                  cropX:cropX
                                  cropY:cropY
                               rotation:rotation]) {
            [self renderFromTexture:inTexture to:outTexture];
        } else {
            dispatch_semaphore_signal(_inflight_semaphore);
        }
    }
}

- (void)drawFrame:(RTCVideoFrame*)frame
        inTexture:(id<MTLTexture>)texture
         rotation:(GPUImageRotationMode)rotation
              fit:(RTCVideoViewObjectFit)objectFit
     displayWidth:(int)displayWidth
    displayHeight:(int)displayHeight{
    @autoreleasepool {
        // Wait until the inflight (curently sent to GPU) command buffer
        // has completed the GPU work.
        dispatch_semaphore_wait(_inflight_semaphore, DISPATCH_TIME_FOREVER);
        if ([self setupTexturesForFrame:frame rotation:rotation fit:objectFit displayWidth:displayWidth displayHeight:displayHeight]) {
            [self renderInTexture:texture];
        } else {
            dispatch_semaphore_signal(_inflight_semaphore);
        }
    }
}

- (void)drawFrame:(id<MTLTexture>)inTexture
       outTexture:(id<MTLTexture>)outTexture
            width:(int)width
           height:(int)height
         rotation:(GPUImageRotationMode)rotation
              fit:(RTCVideoViewObjectFit)objectFit
     displayWidth:(int)displayWidth
    displayHeight:(int)displayHeight
{
    @autoreleasepool {
        // Wait until the inflight (curently sent to GPU) command buffer
        // has completed the GPU work.
        dispatch_semaphore_wait(_inflight_semaphore, DISPATCH_TIME_FOREVER);
        if ([self setupTexturesForWidth:width height:height rotation:rotation fit:objectFit displayWidth:displayWidth displayHeight:displayHeight]) {
            [self renderFromTexture:inTexture to:outTexture];
        } else {
            dispatch_semaphore_signal(_inflight_semaphore);
        }
    }
}


- (void)drawFrame:(id<MTLTexture>)inTexture
       outTexture:(id<MTLTexture>)outTexture
            width:(int)width
           height:(int)height
         rotation:(GPUImageRotationMode)rotation
              fit:(RTCVideoViewObjectFit)objectFit
         viewPort:(MTLViewport)viewPort
      scissorRect:(MTLScissorRect)scissorRect
{
    @autoreleasepool {
        // Wait until the inflight (curently sent to GPU) command buffer
        // has completed the GPU work.
        dispatch_semaphore_wait(_inflight_semaphore, DISPATCH_TIME_FOREVER);
        if ([self setupTexturesForWidth:width height:height rotation:rotation fit:objectFit displayWidth:viewPort.width displayHeight:viewPort.height]) {
            [self renderFromTexture:inTexture to:outTexture viewPort:viewPort scissorRect:scissorRect];
        } else {
            dispatch_semaphore_signal(_inflight_semaphore);
        }
    }
}

- (void)drawFrame:(NSArray<id<FlutterMTLTextureHolder>> *)inTextures
       outTexture:(id<MTLTexture>)outTexture
{
    @autoreleasepool {
        // Wait until the inflight (curently sent to GPU) command buffer
        // has completed the GPU work.
        dispatch_semaphore_wait(_inflight_semaphore, DISPATCH_TIME_FOREVER);
        [self renderFromTextures:inTextures to:outTexture];
    }
}

@end
