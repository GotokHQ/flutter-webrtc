//
//  FlutterGLFilter.m
//  Pods-Runner
//
//  Created by Onyemaechi Okafor on 4/24/20.
//

#import <Foundation/Foundation.h>
#import "FlutterGLFilter.h"


// Hardcode the vertex shader for standard filters, but this can be overridden
NSString *const kGPUImageVertexShaderString = SHADER_STRING
(
 attribute vec4 position;
 attribute vec4 inputTextureCoordinate;
 
 varying vec2 textureCoordinate;
 
 void main()
 {
    gl_Position = position;
    textureCoordinate = inputTextureCoordinate.xy;
}
 );

#if TARGET_IPHONE_SIMULATOR || TARGET_OS_IPHONE

NSString *const kGPUImagePassthroughFragmentShaderString = SHADER_STRING
(
 varying highp vec2 textureCoordinate;
 
 uniform sampler2D inputImageTexture;
 
 void main()
 {
    gl_FragColor = texture2D(inputImageTexture, textureCoordinate);
}
 );

#else

NSString *const kGPUImagePassthroughFragmentShaderString = SHADER_STRING
(
 varying vec2 textureCoordinate;
 
 uniform sampler2D inputImageTexture;
 
 void main()
 {
    gl_FragColor = texture2D(inputImageTexture, textureCoordinate);
}
 );
#endif


@implementation FlutterGLFilter

+ (const GLfloat *)textureCoordinatesForRTCRotation:(RTCVideoRotation)rotationMode {
    static const GLfloat rotation_0[] = {
        // U, V.
        0.0f, 0.0f,
        1.0f, 0.0f,
        0.0f, 1.0f,
        1.0f, 1.0f,
    };
    
    static const GLfloat  rotation_90[] = {
        // U, V.
        1.0f, 0.0f,
        1.0f, 1.0f,
        0.0f, 0.0f,
        0.0f, 1.0f,
    };
    
    static const GLfloat  rotation_180[] = {
        // U, V.
        1.0f, 1.0f,
        0.0f, 1.0f,
        1.0f, 0.0f,
        0.0f, 0.0f,
    };
    
    static const GLfloat  rotation_270[] = {
        // U, V.
        0.0f, 1.0f,
        0.0f, 0.0f,
        1.0f, 1.0f,
        1.0f, 0.0f,
    };
    
    switch (rotationMode) {
        case RTCVideoRotation_0: return rotation_0;
        case RTCVideoRotation_90: return rotation_90;
        case RTCVideoRotation_180: return rotation_180;
        case RTCVideoRotation_270: return rotation_270;
    }
}


+ (const GLfloat *)textureCoordinatesForRotation:(GPUImageRotationMode)rotationMode
{
    static const GLfloat noRotationTextureCoordinates[] = {
        0.0f, 0.0f,
        1.0f, 0.0f,
        0.0f, 1.0f,
        1.0f, 1.0f,
    };
    
    static const GLfloat rotateLeftTextureCoordinates[] = {
        1.0f, 0.0f,
        1.0f, 1.0f,
        0.0f, 0.0f,
        0.0f, 1.0f,
    };
    
    static const GLfloat rotateRightTextureCoordinates[] = {
        0.0f, 1.0f,
        0.0f, 0.0f,
        1.0f, 1.0f,
        1.0f, 0.0f,
    };
    
    static const GLfloat verticalFlipTextureCoordinates[] = {
        0.0f, 1.0f,
        1.0f, 1.0f,
        0.0f,  0.0f,
        1.0f,  0.0f,
    };
    
    static const GLfloat horizontalFlipTextureCoordinates[] = {
        1.0f, 0.0f,
        0.0f, 0.0f,
        1.0f,  1.0f,
        0.0f,  1.0f,
    };
    
    static const GLfloat rotateRightVerticalFlipTextureCoordinates[] = {
        0.0f, 0.0f,
        0.0f, 1.0f,
        1.0f, 0.0f,
        1.0f, 1.0f,
    };
    
    static const GLfloat rotateRightHorizontalFlipTextureCoordinates[] = {
        1.0f, 1.0f,
        1.0f, 0.0f,
        0.0f, 1.0f,
        0.0f, 0.0f,
    };
    
    static const GLfloat rotate180TextureCoordinates[] = {
        1.0f, 1.0f,
        0.0f, 1.0f,
        1.0f, 0.0f,
        0.0f, 0.0f,
    };
    
    switch(rotationMode)
    {
        case kGPUImageNoRotation: return noRotationTextureCoordinates;
        case kGPUImageRotateLeft: return rotateLeftTextureCoordinates;
        case kGPUImageRotateRight: return rotateRightTextureCoordinates;
        case kGPUImageFlipVertical: return verticalFlipTextureCoordinates;
        case kGPUImageFlipHorizonal: return horizontalFlipTextureCoordinates;
        case kGPUImageRotateRightFlipVertical: return rotateRightVerticalFlipTextureCoordinates;
        case kGPUImageRotateRightFlipHorizontal: return rotateRightHorizontalFlipTextureCoordinates;
        case kGPUImageRotateLeftFlipVertical: return rotateRightVerticalFlipTextureCoordinates;
        case kGPUImageRotateLeftFlipHorizontal: return rotateRightHorizontalFlipTextureCoordinates;
        case kGPUImageRotate180: return rotate180TextureCoordinates;
        case kGPUImageRotate270: return rotate180TextureCoordinates;
        case kGPUImageRotate270FlipVertical: return rotate180TextureCoordinates;
        case kGPUImageRotate270FlipHorizontal: return rotate180TextureCoordinates;
    }
}


+ (const float *)textureCoordinatesForMetalRotation:(GPUImageRotationMode)rotationMode
{
    static const float noRotationTextureCoordinates[] = {
        0.0f, 1.0f, // leftBottom
        1.0f, 1.0f, // rightBottom
        0.0f, 0.0f, // topLeft
        1.0f, 0.0f, // topRight
    };
    
    static const float rotateLeftTextureCoordinates[] = {
        1.0f, 1.0f, // rightBottom
        1.0f, 0.0f, // topRight
        0.0f, 1.0f, // leftBottom
        0.0f, 0.0f, // topLeft
    };
    
    static const float rotateLeftVerticalFlipTextureCoordinates[] = {
        1.0f, 0.0f, // rightBottom
        1.0f, 1.0f, // topRight
        0.0f, 0.0f, // leftBottom
        0.0f, 1.0f, // topLeft
    };
    
    static const float rotateLeftHorizontalFlipTextureCoordinates[] = {
        0.0f, 1.0f, // rightBottom
        0.0f, 0.0f, // topRight
        1.0f, 1.0f, // leftBottom
        1.0f, 0.0f, // topLeft
    };
    
    static const float rotateRightTextureCoordinates[] = {
        0.0f, 0.0f, // topLeft
        0.0f, 1.0f, // leftBottom
        1.0f, 0.0f, // topRight
        1.0f, 1.0f, // rightBottom
    };
    
    static const float verticalFlipTextureCoordinates[] = {
        0.0f, 0.0f, // leftBottom
        1.0f, 0.0f, // rightBottom
        0.0f, 1.0f, // topLeft
        1.0f, 1.0f, // topRight
    };
    
    static const float horizontalFlipTextureCoordinates[] = {
        1.0f, 1.0f, // leftBottom
        0.0f, 1.0f, // rightBottom
        1.0f, 0.0f, // topLeft
        0.0f, 0.0f, // topRight
    };
    
    static const float rotateRightVerticalFlipTextureCoordinates[] = {
        0.0f, 1.0f, // topLeft
        0.0f, 0.0f, // leftBottom
        1.0f, 1.0f, // topRight
        1.0f, 0.0f, // rightBottom
    };
    
    static const float rotateRightHorizontalFlipTextureCoordinates[] = {
        1.0f, 0.0f, // topLeft
        1.0f, 1.0f, // leftBottom
        0.0f, 0.0f, // topRight
        0.0f, 1.0f, // rightBottom
    };
    
    static const float rotate180TextureCoordinates[] = {
        1.0f, 0.0f, // topRight
        0.0f, 0.0f, // topLeft
        1.0f, 1.0f, // rightBottom
        0.0f, 1.0f, // leftBottom
    };
    
    static const float rotate270TextureCoordinates[] = {
        0.0f, 0.0f, // topLeft
        0.0f, 1.0f, // leftBottom
        1.0f, 0.0f, // topRight
        1.0f, 1.0f, // rightBottom
    };
    
    static const float rotate270FlipVerticalTextureCoordinates[] = {
        0.0f, 1.0f, // topLeft
        0.0f, 0.0f, // leftBottom
        1.0f, 1.0f, // topRight
        1.0f, 0.0f, // rightBottom
    };
    
    static const float rotate270FlipHorizontalTextureCoordinates[] = {
        1.0f, 0.0f, // topLeft
        1.0f, 1.0f, // leftBottom
        0.0f, 0.0f, // topRight
        0.0f, 1.0f, // rightBottom
    };
    
    switch(rotationMode)
    {
        case kGPUImageNoRotation: return noRotationTextureCoordinates;
        case kGPUImageRotateLeft: return rotateLeftTextureCoordinates;
        case kGPUImageRotateRight: return rotateRightTextureCoordinates;
        case kGPUImageFlipVertical: return verticalFlipTextureCoordinates;
        case kGPUImageFlipHorizonal: return horizontalFlipTextureCoordinates;
        case kGPUImageRotateRightFlipVertical: return rotateRightVerticalFlipTextureCoordinates;
        case kGPUImageRotateRightFlipHorizontal: return rotateRightHorizontalFlipTextureCoordinates;
        case kGPUImageRotateLeftFlipVertical: return rotateLeftVerticalFlipTextureCoordinates;
        case kGPUImageRotateLeftFlipHorizontal: return rotateLeftHorizontalFlipTextureCoordinates;
        case kGPUImageRotate180: return rotate180TextureCoordinates;
        case kGPUImageRotate270: return rotate270TextureCoordinates;
        case kGPUImageRotate270FlipVertical: return rotate270FlipVerticalTextureCoordinates;
        case kGPUImageRotate270FlipHorizontal: return rotate270FlipHorizontalTextureCoordinates;
    }
}

+ (void)textureCoordinatesForMetalRotation:(GPUImageRotationMode)rotationMode widthScaling:(float)widthScaling heightScaling:(float)heightScaling buffer:(float *)buffer {
    [self textureCoordinatesForMetalRotation:rotationMode widthScaling:widthScaling heightScaling:heightScaling cropLeft:0.0f cropRight:1.0f cropTop:0.0f cropBottom:1.0f buffer:buffer];
}

+ (void)textureCoordinatesForMetalRotation:(GPUImageRotationMode)rotationMode cropLeft:(float)cropLeft cropRight:(float)cropRight cropTop:(float)cropTop cropBottom:(float)cropBottom buffer:(float *)buffer
{
    [self textureCoordinatesForMetalRotation:rotationMode widthScaling:1 heightScaling:1 cropLeft:cropLeft cropRight:cropRight cropTop:cropTop cropBottom:cropBottom buffer:buffer];
}

+ (void)textureCoordinatesForMetalRotation:(GPUImageRotationMode)rotationMode widthScaling:(float)widthScaling heightScaling:(float)heightScaling cropLeft:(float)cropLeft cropRight:(float)cropRight cropTop:(float)cropTop cropBottom:(float)cropBottom buffer:(float *)buffer
{
    
    float vertices[] = {
        -widthScaling, -heightScaling,
        widthScaling, -heightScaling,
        -widthScaling,  heightScaling,
        widthScaling,  heightScaling,
    };
    
    switch(rotationMode)
    {
        case kGPUImageNoRotation: {
            //return noRotationTextureCoordinates;
            float values[] = {
                vertices[0], vertices[1], cropLeft, cropBottom, // leftBottom
                vertices[2], vertices[3], cropRight, cropBottom, // rightBottom
                vertices[4], vertices[5], cropLeft, cropTop, // LeftTop
                vertices[6], vertices[7], cropRight, cropTop, // rightTop
            };
            memcpy(buffer, &values, sizeof(values));
        }
            break;
        case kGPUImageRotateLeft: {
            //return rotateLeftTextureCoordinates;
            float values[] = {
                vertices[0], vertices[1], cropRight, cropBottom, // rightBottom
                vertices[2], vertices[3], cropRight, cropTop, // rightTop
                vertices[4], vertices[5], cropLeft, cropBottom, // leftBottom
                vertices[6], vertices[7], cropLeft, cropTop, // leftTop// rightTop
            };
            memcpy(buffer, &values, sizeof(values));
        }
            break;
        case kGPUImageRotateRight: {
            //return rotateRightTextureCoordinates;
            float values[] = {
                vertices[0], vertices[1], cropLeft, cropTop, // leftTop
                vertices[2], vertices[3], cropLeft, cropBottom, // leftBottom
                vertices[4], vertices[5], cropRight, cropTop, // rightTop
                vertices[6], vertices[7], cropRight, cropBottom, // rightBottom
            };
            memcpy(buffer, &values, sizeof(values));
        }
            break;
        case kGPUImageFlipVertical: {
            //return verticalFlipTextureCoordinates;
            float values[] = {
                vertices[0], vertices[1], cropLeft, cropTop, // leftTop
                vertices[2], vertices[3], cropRight, cropTop, // rightTop
                vertices[4], vertices[5], cropLeft, cropBottom, // LeftBottom
                vertices[6], vertices[7], cropRight, cropBottom, // rightBottom
            };
            memcpy(buffer, &values, sizeof(values));
        }
            break;
        case kGPUImageFlipHorizonal: {
            //return horizontalFlipTextureCoordinates;
            float values[] = {
                vertices[0], vertices[1],cropRight, cropBottom, // rightBottom
                vertices[2], vertices[3], cropLeft, cropBottom, // leftBottom
                vertices[4], vertices[5], cropRight, cropTop, // rightTop
                vertices[6], vertices[7], cropLeft, cropTop, // leftTop
            };
            memcpy(buffer, &values, sizeof(values));
        }
            break;
        case kGPUImageRotateRightFlipVertical: {
            //return rotateRightVerticalFlipTextureCoordinates;
            float values[] = {
                vertices[0], vertices[1], cropLeft, cropBottom, // leftBottom
                vertices[2], vertices[3], cropLeft, cropTop, // leftTop
                vertices[4], vertices[5], cropRight, cropBottom, // rightBottom
                vertices[6], vertices[7], cropRight, cropTop, // rightTop
            };
            memcpy(buffer, &values, sizeof(values));
        }
            break;
        case kGPUImageRotateRightFlipHorizontal: {
            //return rotateRightHorizontalFlipTextureCoordinates;
            float values[] = {
                vertices[0], vertices[1], cropLeft, cropBottom, // leftBottom
                vertices[2], vertices[3], cropRight, cropBottom, // rightBottom
                vertices[4], vertices[5], cropLeft, cropTop, // leftTop
                vertices[6], vertices[7], cropRight, cropTop, // rightTop
            };
            memcpy(buffer, &values, sizeof(values));
        }
            break;
        case kGPUImageRotateLeftFlipVertical: {
            //return rotateLeftVerticalFlipTextureCoordinates;
            float values[] = {
                vertices[0], vertices[1], cropRight, cropTop, // rightBottom
                vertices[2], vertices[3], cropRight, cropBottom, // rightTop
                vertices[4], vertices[5], cropLeft, cropTop, // leftBottom
                vertices[6], vertices[7], cropLeft, cropBottom, // leftTop
            };
            memcpy(buffer, &values, sizeof(values));
        }
            break;
        case kGPUImageRotateLeftFlipHorizontal: {
            //return rotateLeftHorizontalFlipTextureCoordinates;
            float values[] = {
                vertices[0], vertices[1], cropLeft, cropBottom, // rightBottom
                vertices[2], vertices[3], cropLeft, cropTop, // rightTop
                vertices[4], vertices[5], cropRight, cropBottom, // leftBottom
                vertices[6], vertices[7], cropRight, cropTop, // leftTop
            };
            memcpy(buffer, &values, sizeof(values));
        }
            break;
        case kGPUImageRotate180: {
            //return rotate180TextureCoordinates;
            float values[] = {
                vertices[0], vertices[1], cropRight, cropTop, // rightTop
                vertices[2], vertices[3], cropLeft, cropTop, // leftTop
                vertices[4], vertices[5], cropRight, cropBottom, // rightBottom
                vertices[6], vertices[7], cropLeft, cropBottom, // leftBottom
            };
            memcpy(buffer, &values, sizeof(values));
        }
            break;
        case kGPUImageRotate270: {
            //return rotate270TextureCoordinates;
            float values[] = {
                vertices[0], vertices[1], cropLeft, cropTop, // leftTop
                vertices[2], vertices[3], cropLeft, cropBottom, // leftBottom
                vertices[4], vertices[5], cropRight, cropTop, // rightTop
                vertices[6], vertices[7], cropRight, cropBottom, // rightBottom
            };
            memcpy(buffer, &values, sizeof(values));
        }
            break;
        case kGPUImageRotate270FlipVertical: {
            //return rotate270FlipVerticalTextureCoordinates;
            float values[] = {
                vertices[0], vertices[1], cropLeft, cropBottom, // leftBottom
                vertices[2], vertices[3], cropLeft, cropTop, // leftTop
                vertices[4], vertices[5], cropRight, cropBottom, // rightBottom
                vertices[6], vertices[7], cropRight, cropTop, // rightTop
            };
            memcpy(buffer, &values, sizeof(values));
        }
            break;
        case kGPUImageRotate270FlipHorizontal: {
            //return rotate270FlipHorizontalTextureCoordinates;
            float values[] = {
                vertices[0], vertices[1], cropRight, cropTop, // rightTop
                vertices[2], vertices[3], cropRight, cropBottom, // rightBottom
                vertices[4], vertices[5], cropLeft, cropTop, // leftTop
                vertices[6], vertices[7], cropLeft, cropBottom, // leftBottom
            };
            memcpy(buffer, &values, sizeof(values));
        }
            break;
    }
}

+ (GPUImageRotationMode)rtcRotationToGPURotation:(RTCVideoRotation )rotation mirror:(BOOL)mirror usingFrontCamera:(BOOL)usingFrontCamera{
    GPUImageRotationMode internalRotation = kGPUImageNoRotation;
        if (usingFrontCamera)
        {
            if (mirror)
            {
                switch(rotation)
                {
                    case RTCVideoRotation_90:internalRotation = kGPUImageRotateLeftFlipVertical; break;
                    case RTCVideoRotation_270:
                        internalRotation = kGPUImageRotateLeftFlipVertical;
                        NSLog(@"GOT ROTATION: 270: kGPUImageRotateLeftFlipVertical");
                        break;
                    case RTCVideoRotation_0:internalRotation = kGPUImageFlipHorizonal; break; // UIDeviceOrientationLandscapeLeft
                    case RTCVideoRotation_180:internalRotation = kGPUImageFlipVertical; break; // UIDeviceOrientationLandscapeRight
                    default:internalRotation = kGPUImageNoRotation;
                }
            }
            else
            {
                switch(rotation)
                {
                    case RTCVideoRotation_90:internalRotation = kGPUImageRotateLeft; break;
                    case RTCVideoRotation_270:internalRotation = kGPUImageRotateLeft; break;
                    case RTCVideoRotation_0:internalRotation = kGPUImageNoRotation; break; // UIDeviceOrientationLandscapeLeft
                    case RTCVideoRotation_180:internalRotation = kGPUImageRotate180; break; // UIDeviceOrientationLandscapeRight
                    default:internalRotation = kGPUImageNoRotation;
                }
            }
    
        }
        else
        {
            if (mirror)
            {
                switch(rotation)
                {
                    case RTCVideoRotation_90:internalRotation = kGPUImageRotateLeftFlipVertical; break;
                    case RTCVideoRotation_270:internalRotation = kGPUImageRotateRightFlipVertical; break;
                    case RTCVideoRotation_0:internalRotation = kGPUImageFlipHorizonal; break; // UIDeviceOrientationLandscapeLeft
                    case RTCVideoRotation_180:internalRotation = kGPUImageFlipVertical; break; // UIDeviceOrientationLandscapeRight
                    default:internalRotation = kGPUImageNoRotation;
                }
            }
            else
            {
                switch(rotation)
                {
                    case RTCVideoRotation_90:
                         internalRotation = kGPUImageRotateLeft;
                        break;
                    case RTCVideoRotation_270:
                        internalRotation = kGPUImageRotateRight;
                        break;
                    case RTCVideoRotation_0:
                        internalRotation = kGPUImageNoRotation;
                        break; // UIDeviceOrientationLandscapeLeft
                    case RTCVideoRotation_180:
                        internalRotation = kGPUImageRotate180;
                        break; // UIDeviceOrientationLandscapeRight
                    default:internalRotation = kGPUImageNoRotation;
                }
            }
        }
    
    //    if (usingFrontCamera)
    //    {
    //        if (mirror)
    //        {
    //            switch(rotation)
    //            {
    //                case RTCVideoRotation_90:internalRotation = kGPUImageRotateRightFlipVertical; break;
    //                case RTCVideoRotation_270:internalRotation = kGPUImageRotateRightFlipHorizontal; break;
    //                case RTCVideoRotation_0:internalRotation = kGPUImageFlipHorizonal; break; // UIDeviceOrientationLandscapeRight
    //                case RTCVideoRotation_180:internalRotation = kGPUImageFlipVertical; break; // UIDeviceOrientationLandscapeLeft
    //                default:internalRotation = kGPUImageNoRotation;
    //            }
    //        }
    //        else
    //        {
    //            switch(rotation)
    //            {
    //                case RTCVideoRotation_90:internalRotation = kGPUImageRotateRight; break;
    //                case RTCVideoRotation_270:internalRotation = kGPUImageRotateLeft; break;
    //                case RTCVideoRotation_0:internalRotation = kGPUImageRotate180; break; // UIDeviceOrientationLandscapeRight
    //                case RTCVideoRotation_180:internalRotation = kGPUImageNoRotation; break; // UIDeviceOrientationLandscapeLeft
    //                default:internalRotation = kGPUImageNoRotation;
    //            }
    //        }
    //
    //    }
    //    else
    //    {
    //        if (mirror)
    //        {
    //            switch(rotation)
    //            {
    //                case RTCVideoRotation_90:internalRotation = kGPUImageRotateRightFlipVertical; break;
    //                case RTCVideoRotation_270:internalRotation = kGPUImageRotate180; break;
    //                case RTCVideoRotation_0:internalRotation = kGPUImageFlipHorizonal; break; // UIDeviceOrientationLandscapeLeft
    //                case RTCVideoRotation_180:internalRotation = kGPUImageFlipVertical; break; // UIDeviceOrientationLandscapeRight
    //                default:internalRotation = kGPUImageNoRotation;
    //            }
    //        }
    //        else
    //        {
    //            switch(rotation)
    //            {
    //                case RTCVideoRotation_90:internalRotation = kGPUImageRotateRight; break;
    //                case RTCVideoRotation_270:internalRotation = kGPUImageRotateLeft; break;
    //                case RTCVideoRotation_0:internalRotation = kGPUImageNoRotation; break; // UIDeviceOrientationLandscapeLeft
    //                case RTCVideoRotation_180:internalRotation = kGPUImageRotate180; break; // UIDeviceOrientationLandscapeRight
    //                default:internalRotation = kGPUImageNoRotation;
    //            }
    //        }
    //    }
    return internalRotation;
}
@end
