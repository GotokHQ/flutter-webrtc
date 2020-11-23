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
#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#else
#import <AppKit/AppKit.h>
#endif
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>
#define MTL_STRINGIFY(s) @ #s

@interface MTLGaussianBlur : NSObject

- (instancetype)initWithDevice:(id<MTLDevice>)device;
- (nullable id<MTLDevice>)currentMetalDevice;
- (void) blur:(nonnull id <MTLTexture>)sourceTexture;
- (void) blur:(nonnull id <MTLTexture>) sourceTexture destinationTexture: (nonnull id <MTLTexture>) destinationTexture;
@end

