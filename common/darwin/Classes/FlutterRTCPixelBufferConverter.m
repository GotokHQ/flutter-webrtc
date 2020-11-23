//
//  FlutterRTCPixelBufferConverter.m
//  Pods-Runner
//
//  Created by Onyemaechi Okafor on 1/22/19.
//

#import "FlutterRTCPixelBufferConverter.h"

@implementation FlutterRTCPixelBufferConverter {
    CGSize _previewSize;
    CVPixelBufferRef _renderTarget;
}

@synthesize previewSize = _previewSize;

// Yuv420 format used for iOS 10+, which is minimum requirement for this plugin.
// Format is used to stream image byte data to dart.
FourCharCode const videoFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;

- initWithPreviewSize:(CGSize)previewSize {
    self = [super init];
    _previewSize = previewSize;
    vImageBuffer_Init(&_destinationBuffer, _previewSize.width, _previewSize.height, 32,
                      kvImageNoFlags);
    vImageBuffer_Init(&_conversionBuffer, _previewSize.width, _previewSize.height, 32,
                      kvImageNoFlags);
    return self;
}

- (void)setPreviewSize:(CGSize)previewSize {
    _previewSize = previewSize;
    vImageBuffer_Init(&_destinationBuffer, _previewSize.width, _previewSize.height, 32,
                      kvImageNoFlags);
    vImageBuffer_Init(&_conversionBuffer, _previewSize.width, _previewSize.height, 32,
                      kvImageNoFlags);
}

// Since video format was changed to kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange we have to
// convert image to a usable format for flutter textures. Which is kCVPixelFormatType_32BGRA.
- (CVPixelBufferRef)convertYUVImageToBGRA:(CVPixelBufferRef)pixelBuffer {
    CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
    
    vImage_YpCbCrToARGB infoYpCbCrToARGB;
    vImage_YpCbCrPixelRange pixelRange;
    pixelRange.Yp_bias = 16;
    pixelRange.CbCr_bias = 128;
    pixelRange.YpRangeMax = 235;
    pixelRange.CbCrRangeMax = 240;
    pixelRange.YpMax = 235;
    pixelRange.YpMin = 16;
    pixelRange.CbCrMax = 240;
    pixelRange.CbCrMin = 16;
    
    vImageConvert_YpCbCrToARGB_GenerateConversion(kvImage_YpCbCrToARGBMatrix_ITU_R_601_4, &pixelRange,
                                                  &infoYpCbCrToARGB, kvImage420Yp8_CbCr8,
                                                  kvImageARGB8888, kvImageNoFlags);
    
    vImage_Buffer sourceLumaBuffer;
    sourceLumaBuffer.data = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0);
    sourceLumaBuffer.height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0);
    sourceLumaBuffer.width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0);
    sourceLumaBuffer.rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0);
    
    vImage_Buffer sourceChromaBuffer;
    sourceChromaBuffer.data = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1);
    sourceChromaBuffer.height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1);
    sourceChromaBuffer.width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1);
    sourceChromaBuffer.rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1);
    
    vImageConvert_420Yp8_CbCr8ToARGB8888(&sourceLumaBuffer, &sourceChromaBuffer, &_destinationBuffer,
                                         &infoYpCbCrToARGB, NULL, 255,
                                         kvImagePrintDiagnosticsToConsole);
    
    CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferRelease(pixelBuffer);
    
    const uint8_t map[4] = {3, 2, 1, 0};
    vImagePermuteChannels_ARGB8888(&_destinationBuffer, &_conversionBuffer, map, kvImageNoFlags);
    
    CVPixelBufferRef newPixelBuffer = NULL;
    CVPixelBufferCreateWithBytes(NULL, _conversionBuffer.width, _conversionBuffer.height,
                                 kCVPixelFormatType_32BGRA, _conversionBuffer.data,
                                 _conversionBuffer.rowBytes, NULL, NULL, NULL, &newPixelBuffer);
    
    return newPixelBuffer;
}
@end
