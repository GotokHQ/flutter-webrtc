//
//  FlutterRTCPixelBufferConverter.h
//  Pods
//
//  Created by Onyemaechi Okafor on 1/22/19.
//

#import <Accelerate/Accelerate.h>
#import <CoreGraphics/CGImage.h>

@interface FlutterRTCPixelBufferConverter : NSObject

@property(nonatomic) vImage_Buffer destinationBuffer;
@property(nonatomic) vImage_Buffer conversionBuffer;
@property(nonatomic) CGSize previewSize;

- (instancetype)initWithPreviewSize:(CGSize)previewSize;

// Since video format was changed to kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange we have to
// convert image to a usable format for flutter textures. Which is kCVPixelFormatType_32BGRA.
- (CVPixelBufferRef)convertYUVImageToBGRA:(CVPixelBufferRef)pixelBuffer;


@end
