/*
 *  Copyright 2017 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#import <Foundation/Foundation.h>
#import <WebRTC/RTCVideoFrame.h>
#import <WebRTC/RTCVideoFrameBuffer.h>
#import <WebRTC/RTCCVPixelBuffer.h>
#import "FlutterGLFilter.h"
#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#else
#import <AppKit/AppKit.h>
#endif
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#define MTL_STRINGIFY(s) @ #s


NS_ASSUME_NONNULL_BEGIN


extern void getCubeVertexDataWithObjectFit(float frameWidth, float frameHeight, GPUImageRotationMode rotation, RTCVideoViewObjectFit objectFit, float displayWidth, float displayHeight, float *buffer);

@protocol FlutterMTLTextureHolder <NSObject>


@property(readonly, nonatomic) id<MTLTexture> texture;
@property(readwrite, nonatomic) CGRect bounds;
@property(readwrite, nonatomic) RTCVideoViewObjectFit objectFit;
@property(readonly, nonatomic) id<MTLBuffer> vertexBuffer;
@end

/**
 * Protocol defining ability to render RTCVideoFrame in Metal enabled views.
 */
@protocol MTLRenderer <NSObject>

/**
 * Method to be implemented to perform actual rendering of the provided frame.
 *
 * @param frame The frame to be rendered.
 */
- (void)drawFrame:(RTCVideoFrame*)frame inTexture:(id<MTLTexture>)texture rotation:(GPUImageRotationMode)rotation;

- (void)drawFrame:(id<MTLTexture>)inTexture
       outTexture:(id<MTLTexture>)outTexture
            width:(int)width
           height:(int)height
        cropWidth:(int)cropWidth
       cropHeight:(int)cropHeight
            cropX:(int)cropX
            cropY:(int)cropY
         rotation:(GPUImageRotationMode)rotation;

- (void)drawFrame:(RTCVideoFrame*)frame
        inTexture:(id<MTLTexture>)texture
         rotation:(GPUImageRotationMode)rotation
              fit:(RTCVideoViewObjectFit)objectFit
     displayWidth:(int)displayWidth
    displayHeight:(int)displayHeight;

- (void)drawFrame:(id<MTLTexture>)inTexture
       outTexture:(id<MTLTexture>)outTexture
            width:(int)width
           height:(int)height
         rotation:(GPUImageRotationMode)rotation
              fit:(RTCVideoViewObjectFit)objectFit
     displayWidth:(int)displayWidth
    displayHeight:(int)displayHeight;

- (void)drawFrame:(id<MTLTexture>)inTexture
       outTexture:(id<MTLTexture>)outTexture
            width:(int)width
           height:(int)height
         rotation:(GPUImageRotationMode)rotation
              fit:(RTCVideoViewObjectFit)objectFit
         viewPort:(MTLViewport)viewPort
      scissorRect:(MTLScissorRect)scissorRect;

- (void)drawFrame:(NSArray<id<FlutterMTLTextureHolder>> *)inTextures
       outTexture:(id<MTLTexture>)outTexture;
@end

/**
 * Implementation of RTCMTLRenderer protocol.
 */
NS_AVAILABLE(10_11, 9_0)



@interface FlutterMTLRenderer : NSObject <MTLRenderer>

/** @abstract   A wrapped RTCVideoRotation, or nil.
    @discussion When not nil, the rotation of the actual frame is ignored when rendering.
 */
@property(atomic, nullable) NSValue *rotationOverride;
- (instancetype)initWithDevice:(id<MTLDevice>)device;
- (instancetype)initWithDevice:(id<MTLDevice>)device descriptor:(MTLRenderPassDescriptor*)descriptor;
- (nullable id<MTLDevice>)currentMetalDevice;
- (NSString *)shaderSource;
- (BOOL)setupTexturesForFrame:(nonnull RTCVideoFrame *)frame rotation:(GPUImageRotationMode)rotation;
- (BOOL)setupTexturesForFrame:(nonnull RTCVideoFrame *)frame rotation:(GPUImageRotationMode)rotationValue fit:(RTCVideoViewObjectFit)objectFit displayWidth:(int)displayWidth displayHeight:(int) displayHeight;
- (BOOL)setupTexturesForWidth:(int)width height:(int)height rotation:(GPUImageRotationMode)rotationValue fit:(RTCVideoViewObjectFit)objectFit displayWidth:(int)displayWidth displayHeight:(int) displayHeight;

- (void)uploadTexturesToRenderEncoder:(id<MTLRenderCommandEncoder>)renderEncoder;

- (void)getWidth:(int *)width
          height:(int *)height
       cropWidth:(int *)cropWidth
      cropHeight:(int *)cropHeight
           cropX:(int *)cropX
           cropY:(int *)cropY
         ofFrame:(nonnull RTCVideoFrame *)frame;
@end

NS_ASSUME_NONNULL_END
