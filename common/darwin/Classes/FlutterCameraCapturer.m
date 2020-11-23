/*
 *  Copyright 2017 The WebRTC Project Authors. All rights reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#import <WebRTC/RTCLogging.h>
#import <WebRTC/RTCMediaConstraints.h>
#import "FlutterCameraCapturer.h"
#import "FlutterVideoCapturer.h"
#import "SamplesInterceptorDelegate.h"

const Float64 kFramerateLimit = 30.0;

NSString * const kRTCMediaConstraintsMinWidth = @"minWidth";
NSString * const kRTCMediaConstraintsMinHeight = @"minHeight";


@implementation FlutterCameraCapturer {
    NSDictionary *_constraints;
    BOOL _facing;
}

@synthesize facing = _facing;

- (instancetype)initWithVideoSource:(RTCVideoSource *)source
                        constraints:(NSDictionary *)constraints{
    if (self = [super init]) {
        _constraints = constraints;
        _camera = [[FlutterCamera alloc] initWithDelegate:source audioEnabled:self.audioEnabled];
        _facing = [self getfacing];
    }
    return self;
}

- ( NSDictionary *)defaultMediaStreamConstraints {
    return @{ kRTCMediaConstraintsMinWidth: @"1280",
              kRTCMediaConstraintsMinHeight: @"720",
            };
}

- (BOOL)audioEnabled {
    NSNumber *audioEnabled = _constraints[@"audioEnabled"];
    if (audioEnabled) {
        return [audioEnabled boolValue];
    }
    return NO;
}

- (AVCaptureDevicePosition)positionForFacingMode:(NSString*)facingMode {
    AVCaptureDevicePosition position;
    if ([facingMode isEqualToString:@"environment"]) {
        position = AVCaptureDevicePositionBack;
    } else if ([facingMode isEqualToString:@"user"]) {
        position = AVCaptureDevicePositionFront;
    } else {
        // If the specified facingMode value is not supported, fall back to
        // the default video device.
        position = AVCaptureDevicePositionUnspecified;
    }
    return position;
}

- (BOOL)getfacing {
    AVCaptureDevicePosition position = [self positionForFacingMode:_constraints[@"facingMode"]];
    return AVCaptureDevicePositionFront == position;
}

- (void)startCapture:(OnSuccess)success onError:(OnError)onError {
    AVCaptureDevice *videoDevice;
    id optionalVideoConstraints = _constraints[@"optional"];
    if (optionalVideoConstraints
        && [optionalVideoConstraints isKindOfClass:[NSArray class]]) {
        NSArray *options = optionalVideoConstraints;
        for (id item in options) {
            if ([item isKindOfClass:[NSDictionary class]]) {
                NSString *sourceId = ((NSDictionary *)item)[@"sourceId"];
                if (sourceId) {
                    videoDevice = [AVCaptureDevice deviceWithUniqueID:sourceId];
                    if (videoDevice) {
                        break;
                    }
                }
            }
        }
    }
    if (!videoDevice) {
        // constraints.video.facingMode
        //
        // https://www.w3.org/TR/mediacapture-streams/#def-constraint-facingMode
        id facingMode = _constraints[@"facingMode"];
        if (facingMode && [facingMode isKindOfClass:[NSString class]]) {
            AVCaptureDevicePosition position = [self positionForFacingMode:facingMode];
            _facing = [self getfacing];
            if (AVCaptureDevicePositionUnspecified != position) {
                videoDevice = [self findDeviceForPosition:position];
            }
        }
    }
    if (!videoDevice) {
        videoDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    }
    
    if (videoDevice) {
        AVCaptureDeviceFormat *format = [self selectFormatForDevice:videoDevice];
        if (format == nil) {
            RTCLogError(@"No valid formats for device %@", videoDevice);
            if (onError) {
                onError(@"No valid formats for device", @"");
            }
            return;
        }
        NSInteger fps = [self selectFpsForFormat:format];
        [_camera startCaptureWithDevice:videoDevice format:format fps:fps completionHandler:^(NSError * error){
            if (error) {
                onError(@"failed", error.localizedDescription);
                return;
            }
            if (success) {
                success();
            }
        }];
    } else {
        if (onError) {
            onError(@"No device available", @"");
        }
    }
}

- (void)restartCapture:(OnSuccess)success onError:(OnError)onError {
    [_camera restartCompletionHandler:^(NSError * error){
        if (error) {
            onError(@"failed", error.localizedDescription);
            return;
        }
        if (success) {
            success();
        }
    }];
}

- (void)stopRunning:(OnSuccess)success onError:(OnError)onError {
    [_camera stopRunning:^(NSError * error){
        if (error) {
            onError(@"failed", error.localizedDescription);
            return;
        }
        if (success) {
            success();
        }
    }];
}

- (void)startRunning:(OnSuccess)success onError:(OnError)onError {
    [_camera startRunning:^(NSError * error){
        if (error) {
            onError(@"failed", error.localizedDescription);
            return;
        }
        if (success) {
            success();
        }
    }];
}

- (void)stopCapture:(OnSuccess)success onError: (OnError)error {
    [_camera stopCapture];
    if (success) {
        success();
    }
}

- (void)switchCamera:(OnSuccess)success onError: (OnError)onError {
    BOOL usingFrontCamera = !_facing;
    AVCaptureDevicePosition position =
    usingFrontCamera ? AVCaptureDevicePositionFront : AVCaptureDevicePositionBack;
    AVCaptureDevice *device = [self findDeviceForPosition:position];
    AVCaptureDeviceFormat *format = [self selectFormatForDevice:device];
    if (format == nil && onError) {
        RTCLogError(@"No valid formats for device %@", device);
        onError(@"No valid formats for device", @"");
        return;
    }
    NSInteger fps = [self selectFpsForFormat:format];
    __weak FlutterCameraCapturer *weakSelf = self;
    [_camera pauseCapture:YES completionHandler:nil];
    [_camera startCaptureWithDevice:device format:format fps:fps completionHandler:^(NSError * error) {
        FlutterCameraCapturer *strongSelf = weakSelf;
        [strongSelf->_camera pauseCapture:NO completionHandler:nil];
        if (error) {
            onError(@"failed", error.localizedDescription);
            return;
        }
        strongSelf->_facing = usingFrontCamera;
        if (success) {
            success();
        }
    }];
}

#pragma mark - Private

- (AVCaptureDevice *)findDeviceForPosition:(AVCaptureDevicePosition)position {
    NSArray<AVCaptureDevice *> *captureDevices = [FlutterCamera captureDevices];
    for (AVCaptureDevice *device in captureDevices) {
        if (device.position == position) {
            return device;
        }
    }
    return captureDevices[0];
}


- (AVCaptureDeviceFormat *)selectFormatForDevice:(AVCaptureDevice *)device{
    NSArray<AVCaptureDeviceFormat *> *formats =
    [FlutterCamera supportedFormatsForDevice:device];
    AVCaptureDeviceFormat *selectedFormat = nil;
    int currentDiff = INT_MAX;
    NSDictionary *mandatoryConstraints = _constraints[@"mandatory"];
    NSDictionary *defaultConstraints = self.defaultMediaStreamConstraints;
    NSString *minWidth = mandatoryConstraints[kRTCMediaConstraintsMinWidth];
    if (!minWidth) {
        minWidth = defaultConstraints[kRTCMediaConstraintsMinWidth];
    }
    NSString *minHeight = mandatoryConstraints[kRTCMediaConstraintsMinHeight];
    if (!minHeight) {
        minHeight = defaultConstraints[kRTCMediaConstraintsMinHeight];
    }
    for (AVCaptureDeviceFormat *format in formats) {
        CMVideoDimensions dimension = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
        FourCharCode pixelFormat = CMFormatDescriptionGetMediaSubType(format.formatDescription);
        int diff = abs([minWidth intValue] - dimension.width) + abs([minHeight intValue] - dimension.height);
        if (diff < currentDiff) {
            selectedFormat = format;
            currentDiff = diff;
        } else if (diff == currentDiff && pixelFormat == [_camera preferredOutputPixelFormat]) {
            selectedFormat = format;
        }
    }
    return selectedFormat;
}

- (NSInteger)selectFpsForFormat:(AVCaptureDeviceFormat *)format {
    Float64 maxSupportedFramerate = 0;
    for (AVFrameRateRange *fpsRange in format.videoSupportedFrameRateRanges) {
        maxSupportedFramerate = fmax(maxSupportedFramerate, fpsRange.maxFrameRate);
    }
    return fmin(maxSupportedFramerate, kFramerateLimit);
}

@end
