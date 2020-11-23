/*
 *  Copyright 2018 The WebRTC Project Authors. All rights reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#import "MTLRGBRenderer.h"

static NSString *const shaderSource = MTL_STRINGIFY(
using namespace metal;

typedef struct {
  packed_float2 position;
  packed_float2 texcoord;
} Vertex;

typedef struct {
  float4 position[[position]];
  float2 texcoord;
} VertexIO;

vertex VertexIO vertexPassthrough(constant Vertex *verticies[[buffer(0)]],
                                  uint vid[[vertex_id]]) {
  VertexIO out;
  constant Vertex &v = verticies[vid];
  out.position = float4(float2(v.position), 0.0, 1.0);
  out.texcoord = v.texcoord;
  return out;
}

fragment half4 fragmentColorConversion(VertexIO in[[stage_in]],
                                       texture2d<half, access::sample> texture[[texture(0)]],
                                       constant bool &isARGB[[buffer(0)]]) {
  constexpr sampler s(address::clamp_to_edge, filter::linear);

  half4 out = texture.sample(s, in.texcoord);
  if (isARGB) {
    out = half4(out.g, out.b, out.a, out.r);
  }

  return out;
});

@implementation MTLRGBRenderer {
  // Textures.
  CVMetalTextureCacheRef _textureCache;
  id<MTLTexture> _texture;

  // Uniforms.
  id<MTLBuffer> _uniformsBuffer;
}

- (NSString *)shaderSource {
  return shaderSource;
}

- (BOOL)initializeTextureCache {
  CVReturn status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, [self currentMetalDevice],
                                              nil, &_textureCache);
  if (status != kCVReturnSuccess) {
    NSLog(@"Metal: Failed to initialize metal texture cache. Return status is %d", status);
    return NO;
  }

  return YES;
}

- (void)getWidth:(int *)width
          height:(int *)height
       cropWidth:(int *)cropWidth
      cropHeight:(int *)cropHeight
           cropX:(int *)cropX
           cropY:(int *)cropY
         ofFrame:(nonnull RTCVideoFrame *)frame {
      RTCCVPixelBuffer *pixelBuffer = (RTCCVPixelBuffer *)frame.buffer;
      *width = CVPixelBufferGetWidth(pixelBuffer.pixelBuffer);
      *height = CVPixelBufferGetHeight(pixelBuffer.pixelBuffer);
      *cropWidth = pixelBuffer.cropWidth;
      *cropHeight = pixelBuffer.cropHeight;
      *cropX = pixelBuffer.cropX;
      *cropY = pixelBuffer.cropY;
}

- (BOOL)setupTexturesForFrame:(nonnull RTCVideoFrame *)frame rotation:(GPUImageRotationMode)rotation{
    if (![super setupTexturesForFrame:frame rotation:rotation]) {
    return NO;
  }
  return [self setupUpWithFrame:frame];
}


- (BOOL)setupTexturesForFrame:(nonnull RTCVideoFrame *)frame rotation:(GPUImageRotationMode)rotation fit:(RTCVideoViewObjectFit)objectFit displayWidth:(int)displayWidth displayHeight:(int) displayHeight {
    if (![super setupTexturesForFrame:frame rotation:rotation fit:objectFit displayWidth:displayWidth displayHeight:displayHeight]) {
    return NO;
  }
  return [self setupUpWithFrame:frame];
}

- (BOOL)setupUpWithFrame:(nonnull RTCVideoFrame *)frame {
  id<MTLTexture> gpuTexture = nil;
  CVMetalTextureRef textureOut = nullptr;
  bool isARGB;
  CVPixelBufferRef pixelBuffer = ((RTCCVPixelBuffer *)frame.buffer).pixelBuffer;
  int width = CVPixelBufferGetWidth(pixelBuffer);
  int height = CVPixelBufferGetHeight(pixelBuffer);
  OSType pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer);

  MTLPixelFormat mtlPixelFormat;
  if (pixelFormat == kCVPixelFormatType_32BGRA) {
    mtlPixelFormat = MTLPixelFormatBGRA8Unorm;
    isARGB = false;
  } else if (pixelFormat == kCVPixelFormatType_32ARGB) {
    mtlPixelFormat = MTLPixelFormatRGBA8Unorm;
    isARGB = true;
  } else {
    return NO;
  }

  if (!_textureCache) {
    [self initializeTextureCache];
  }
  CVReturn result = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, _textureCache, pixelBuffer, nil, mtlPixelFormat,
                width, height, 0, &textureOut);
  if (result == kCVReturnSuccess) {
    gpuTexture = CVMetalTextureGetTexture(textureOut);
  }
  CVBufferRelease(textureOut);

  if (gpuTexture != nil) {
    _texture = gpuTexture;
    _uniformsBuffer =
        [[self currentMetalDevice] newBufferWithBytes:&isARGB
                                               length:sizeof(isARGB)
                                              options:MTLResourceCPUCacheModeDefaultCache];
    return YES;
  }

  return NO;
}

- (void)uploadTexturesToRenderEncoder:(id<MTLRenderCommandEncoder>)renderEncoder {
  [renderEncoder setFragmentTexture:_texture atIndex:0];
  [renderEncoder setFragmentBuffer:_uniformsBuffer offset:0 atIndex:0];
}

- (void)dealloc {
  if (_textureCache) {
    CFRelease(_textureCache);
  }
}

@end
