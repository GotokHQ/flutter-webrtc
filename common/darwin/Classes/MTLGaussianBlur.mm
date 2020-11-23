/*
 *  Copyright 2017 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#import "MTLGaussianBlur.h"

static const NSInteger kMaxInflightBuffers = 1;
static NSString *const commandBufferLabel = @"GaussianBuffer";

NS_AVAILABLE(10_11, 9_0)
@implementation MTLGaussianBlur {
    
    // Controller.
    dispatch_semaphore_t _inflight_semaphore;
    
    // Renderer.
    id<MTLDevice> _device;
    id<MTLCommandQueue> _commandQueue;
    id<MTLLibrary> _defaultLibrary;
    id<MTLRenderPipelineState> _pipelineState;
    MPSImageGaussianBlur *_gaussBlur;
}


- (instancetype)initWithDevice:(id<MTLDevice>)device{
    if (self = [super init]) {
        _device = device;
        _inflight_semaphore = dispatch_semaphore_create(kMaxInflightBuffers);
        _gaussBlur = [[MPSImageGaussianBlur alloc] initWithDevice:_device sigma:30];
        [self setupMetal];
    }
    
    return self;
}


#pragma mark - Inheritance

- (id<MTLDevice>)currentMetalDevice {
    return _device;
}

#pragma mark - GPU methods

- (BOOL)setupMetal {
    // Create a new command queue.
    _commandQueue = [_device newCommandQueue];
    return YES;
}


- (void)renderFrom:(id<MTLTexture>)from to:(id<MTLTexture>)to {
    id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    commandBuffer.label = commandBufferLabel;
    
    __block dispatch_semaphore_t block_semaphore = _inflight_semaphore;
    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> _Nonnull) {
        // GPU work completed.
        dispatch_semaphore_signal(block_semaphore);
    }];
    
    
    [_gaussBlur encodeToCommandBuffer:commandBuffer sourceTexture:from destinationTexture:to];
    // CPU work is completed, GPU work can be started.
    [commandBuffer commit];
}

- (void)renderInPlace:(id<MTLTexture>)texture {
    id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    commandBuffer.label = commandBufferLabel;
    
    __block dispatch_semaphore_t block_semaphore = _inflight_semaphore;
    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> _Nonnull) {
        // GPU work completed.
        dispatch_semaphore_signal(block_semaphore);
    }];
    
    
    if([_gaussBlur encodeToCommandBuffer:commandBuffer inPlaceTexture:&texture fallbackCopyAllocator:nil]) {
        // CPU work is completed, GPU work can be started.
        [commandBuffer commit];
    }
    
}

- (void) blur:(nonnull id <MTLTexture>)sourceTexture{
    @autoreleasepool {
        // Wait until the inflight (curently sent to GPU) command buffer
        // has completed the GPU work.
        dispatch_semaphore_wait(_inflight_semaphore, DISPATCH_TIME_FOREVER);
        [self renderInPlace:sourceTexture];
    }
}

- (void) blur:(nonnull id <MTLTexture>) sourceTexture destinationTexture: (nonnull id <MTLTexture>) destinationTexture{
    @autoreleasepool {
        // Wait until the inflight (curently sent to GPU) command buffer
        // has completed the GPU work.
        dispatch_semaphore_wait(_inflight_semaphore, DISPATCH_TIME_FOREVER);
        [self renderFrom:sourceTexture to:destinationTexture];
    }
}

@end
