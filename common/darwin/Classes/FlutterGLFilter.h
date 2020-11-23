#import <Foundation/Foundation.h>
#import <WebRTC/RTCVideoFrame.h>

#define STRINGIZE(x) #x
#define STRINGIZE2(x) STRINGIZE(x)
#define SHADER_STRING(text) @ STRINGIZE2(text)

#define GPUImageHashIdentifier #
#define GPUImageWrappedLabel(x) x
#define GPUImageEscapedHashIdentifier(a) GPUImageWrappedLabel(GPUImageHashIdentifier)a

extern NSString *const kGPUImageVertexShaderString;
extern NSString *const kGPUImagePassthroughFragmentShaderString;

typedef NS_ENUM(NSUInteger, RTCVideoViewObjectFit) {
    RTCVideoViewObjectFitContain,           // Maintains the aspect ratio of the source image, adding bars of the specified background color
    RTCVideoViewObjectFitCover     // Maintains the aspect ratio of the source image, zooming in on its center to fill the view
};

typedef NS_ENUM(NSUInteger, GLFillModeType) {
    kGLFillModeStretch,                       // Stretch to fill the full view, which may distort the image outside of its normal aspect ratio
    kGLFillModePreserveAspectRatio,           // Maintains the aspect ratio of the source image, adding bars of the specified background color
    kGLFillModePreserveAspectRatioAndFill     // Maintains the aspect ratio of the source image, zooming in on its center to fill the view
};

typedef NS_ENUM(NSUInteger, GPUImageRotationMode) {
    kGPUImageNoRotation,
    kGPUImageRotateLeft,
    kGPUImageRotateRight,
    kGPUImageFlipVertical,
    kGPUImageFlipHorizonal,
    kGPUImageRotateRightFlipVertical,
    kGPUImageRotateRightFlipHorizontal,
    kGPUImageRotateLeftFlipVertical,
    kGPUImageRotateLeftFlipHorizontal,
    kGPUImageRotate180,
    kGPUImageRotate270,
    kGPUImageRotate270FlipVertical,
    kGPUImageRotate270FlipHorizontal,
};

@interface FlutterGLFilter : NSObject


#pragma mark -
#pragma mark Rendering

+ (const GLfloat *)textureCoordinatesForRotation:(GPUImageRotationMode)rotationMode;
+ (const GLfloat *)textureCoordinatesForRTCRotation:(RTCVideoRotation)rotationMode;
+ (const float *)textureCoordinatesForMetalRotation:(GPUImageRotationMode)rotationMode;
+ (void)textureCoordinatesForMetalRotation:(GPUImageRotationMode)rotationMode cropLeft:(float)cropLeft cropRight:(float)cropRight cropTop:(float)cropTop cropBottom:(float)cropBottom buffer:(float *)buffer;
+ (void)textureCoordinatesForMetalRotation:(GPUImageRotationMode)rotationMode widthScaling:(float)widthScaling heightScaling:(float)heightScaling buffer:(float *)buffer;
+ (GPUImageRotationMode)rtcRotationToGPURotation:(RTCVideoRotation )rotation mirror:(BOOL)mirror usingFrontCamera:(BOOL)usingFrontCamera;
@end
