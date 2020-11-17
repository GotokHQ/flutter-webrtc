package com.cloudwebrtc.webrtc;

/*
 *  Copyright 2018 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */


import android.opengl.GLES11Ext;
import android.opengl.GLES20;
import android.util.Log;

import androidx.annotation.Nullable;

import org.webrtc.GlShader;
import org.webrtc.GlUtil;
import org.webrtc.RendererCommon;

import java.nio.FloatBuffer;

/**
 * Helper class to implement an instance of RendererCommon.GlDrawer that can accept multiple input
 * sources (OES, RGB, or YUV) using a generic fragment shader as input. The generic fragment shader
 * should sample pixel values from the function "sample" that will be provided by this class and
 * provides an abstraction for the input source type (OES, RGB, or YUV). The texture coordinate
 * variable name will be "tc" and the texture matrix in the vertex shader will be "tex_mat". The
 * simplest possible generic shader that just draws pixel from the frame unmodified looks like:
 * void main() {
 *   gl_FragColor = sample(tc);
 * }
 * This class covers the cases for most simple shaders and generates the necessary boiler plate.
 * Advanced shaders can always implement RendererCommon.GlDrawer directly.
 */
class GLBlurDrawer implements RendererCommon.GlDrawer {
    private static final String FRAGMENT_SHADER = "void main() {\n"
            + "  lowp vec3 sum = vec3(0.0);\n"
            + "  lowp vec4 fragColor = sample(tc);\n"
            + "  sum += sample(blurCoordinates[0]).rgb * 0.05;\n"
            + "  sum += sample(blurCoordinates[1]).rgb * 0.09;\n"
            + "  sum += sample(blurCoordinates[2]).rgb * 0.12;\n"
            + "  sum += sample(blurCoordinates[3]).rgb * 0.15;\n"
            + "  sum += sample(blurCoordinates[4]).rgb * 0.18;\n"
            + "  sum += sample(blurCoordinates[5]).rgb * 0.15;\n"
            + "  sum += sample(blurCoordinates[6]).rgb * 0.12;\n"
            + "  sum += sample(blurCoordinates[7]).rgb * 0.09;\n"
            + "  sum += sample(blurCoordinates[8]).rgb * 0.05;\n"
            + "  gl_FragColor = vec4(sum, fragColor.a);\n"
            + "}\n";
    private static final String FRAGMENT_SHADER_YUV =
            // Difference in texture coordinate corresponding to one
            // sub-pixel in the x direction.
            "uniform vec2 xUnit;\n"
                    // Color conversion coefficients, including constant term
                    + "uniform vec4 coeffs;\n"
                    + "\n"
                    + "void main() {\n"
                    // Since the alpha read from the texture is always 1, this could
                    // be written as a mat4 x vec4 multiply. However, that seems to
                    // give a worse framerate, possibly because the additional
                    // multiplies by 1.0 consume resources. TODO(nisse): Could also
                    // try to do it as a vec3 x mat3x4, followed by an add in of a
                    // constant vector.
                    + "  lowp vec4 fragColor = sample2(tc);\n"
                    + "  sum += sample2(blurCoordinates[0]).rgb * 0.05;\n"
                    + "  sum += sample2(blurCoordinates[1]).rgb * 0.09;\n"
                    + "  sum += sample2(blurCoordinates[2]).rgb * 0.12;\n"
                    + "  sum += sample2(blurCoordinates[3]).rgb * 0.15;\n"
                    + "  sum += sample2(blurCoordinates[4]).rgb * 0.18;\n"
                    + "  sum += sample2(blurCoordinates[5]).rgb * 0.15;\n"
                    + "  sum += sample2(blurCoordinates[6]).rgb * 0.12;\n"
                    + "  sum += sample2(blurCoordinates[7]).rgb * 0.09;\n"
                    + "  sum += sample2(blurCoordinates[8]).rgb * 0.05;\n"
                    + "  gl_FragColor = vec4(sum, fragColor.a);\n"
                    + "}\n";
    /**
     * The different shader types representing different input sources. YUV here represents three
     * separate Y, U, V textures.
     */
    public static enum ShaderType { OES, RGB, YUV }

    /**
     * The shader callbacks is used to customize behavior for a GlDrawer. It provides a hook to set
     * uniform variables in the shader before a frame is drawn.
     */
    public static interface ShaderCallbacks {
        /**
         * This callback is called when a new shader has been compiled and created. It will be called
         * for the first frame as well as when the shader type is changed. This callback can be used to
         * do custom initialization of the shader that only needs to happen once.
         */
        void onNewShader(GlShader shader, int frameWidth, int frameHeight);

        /**
         * This callback is called before rendering a frame. It can be used to do custom preparation of
         * the shader that needs to happen every frame.
         */
        void onPrepareShader(GlShader shader, float[] texMatrix, int frameWidth, int frameHeight,
                             int viewportWidth, int viewportHeight);
    }

    private static final String INPUT_VERTEX_COORDINATE_NAME = "in_pos";
    private static final String INPUT_TEXTURE_COORDINATE_NAME = "in_tc";
    private static final String TEXTURE_MATRIX_NAME = "tex_mat";
    private static final int NUM_PASSES = 2;
    public static final String TEXEL_WIDTH_OFFSET_NAME = "texelWidthOffset";
    public static final String TEXEL_HEIGHT_OFFSET_NAME = "texelHeightOffset";
    private static final String DEFAULT_VERTEX_SHADER_STRING = "varying vec2 tc;\n"
            + "attribute vec4 in_pos;\n"
            + "attribute vec4 in_tc;\n"
            + "uniform mat4 tex_mat;\n"
            + "uniform float texelWidthOffset;\n"
            + "uniform float texelHeightOffset;\n"
            + "const int GAUSSIAN_SAMPLES = 9;\n"
            + "varying vec2 blurCoordinates[GAUSSIAN_SAMPLES];\n"
            + "void main() {\n"
            + "  gl_Position = in_pos;\n"
            + "  tc = (tex_mat * in_tc).xy;\n"
            + "  // Calculate the in_poss for the blur\n"
            + "	 int multiplier = 0;\n"
            + "	 vec2 blurStep;\n"
            +"   vec2 singleStepOffset = vec2(texelHeightOffset, texelWidthOffset);\n"
            +"    \n"
            +"	 for (int i = 0; i < GAUSSIAN_SAMPLES; i++)\n"
            +"   {\n"
            +"		multiplier = (i - ((GAUSSIAN_SAMPLES - 1) / 2));\n"
            +"      // Blur in x (horizontal)\n"
            +"      blurStep = float(multiplier) * singleStepOffset;\n"
            +"		blurCoordinates[i] = (tex_mat * in_tc).xy + blurStep;\n"
            +"	  }\n"
            + "}\n";

    // Vertex coordinates in Normalized Device Coordinates, i.e. (-1, -1) is bottom-left and (1, 1)
    // is top-right.
    private static final FloatBuffer FULL_RECTANGLE_BUFFER = GlUtil.createFloatBuffer(new float[] {
            -1.0f, -1.0f, // Bottom left.
            1.0f, -1.0f, // Bottom right.
            -1.0f, 1.0f, // Top left.
            1.0f, 1.0f, // Top right.
    });

    // Texture coordinates - (0, 0) is bottom-left and (1, 1) is top-right.
    private static final FloatBuffer FULL_RECTANGLE_TEXTURE_BUFFER =
            GlUtil.createFloatBuffer(new float[] {
                    0.0f, 0.0f, // Bottom left.
                    1.0f, 0.0f, // Bottom right.
                    0.0f, 1.0f, // Top left.
                    1.0f, 1.0f, // Top right.
            });

    static String createFragmentShaderString(String genericFragmentSource, ShaderType shaderType) {
        final StringBuilder stringBuilder = new StringBuilder();
        if (shaderType == ShaderType.OES) {
            stringBuilder.append("#extension GL_OES_EGL_image_external : require\n");
        }
        stringBuilder.append("precision mediump float;\n");
        stringBuilder.append("varying vec2 tc;\n");
        stringBuilder.append("const lowp int GAUSSIAN_SAMPLES = 9;\n");
        stringBuilder.append("varying highp vec2 blurCoordinates[GAUSSIAN_SAMPLES];\n");

        if (shaderType == ShaderType.YUV) {
//            stringBuilder.append("uniform sampler2D y_tex;\n");
//            stringBuilder.append("uniform sampler2D u_tex;\n");
//            stringBuilder.append("uniform sampler2D v_tex;\n");
//
//            stringBuilder.append("vec4 sample(vec2 p) {\n");
//            stringBuilder.append("  float y = texture2D(y_tex, p).r * 1.16438;\n");
//            stringBuilder.append("  float u = texture2D(u_tex, p).r;\n");
//            stringBuilder.append("  float v = texture2D(v_tex, p).r;\n");
//            stringBuilder.append("  return vec4(y + 1.59603 * v - 0.874202,\n");
//            stringBuilder.append("    y - 0.391762 * u - 0.812968 * v + 0.531668,\n");
//            stringBuilder.append("    y + 2.01723 * u - 1.08563, 1);\n");
//            stringBuilder.append("}\n");
//
//            stringBuilder.append("vec4 sample2(vec2 p) {\n");
//            stringBuilder.append("  float r = coeffs.a + dot(coeffs.rgb, sample(p - 1.5 * xUnit).rgb);\n");
//            stringBuilder.append("  float g = coeffs.a + dot(coeffs.rgb, sample(p - 0.5 * xUnit).rgb);\n");
//            stringBuilder.append("  float b = coeffs.a + dot(coeffs.rgb, sample(p + 0.5 * xUnit).rgb);\n");
//            stringBuilder.append("  float a = coeffs.a + dot(coeffs.rgb, sample(p + 1.5 * xUnit).rgb)\n");
//            stringBuilder.append("  return vec4(r, g, b, a);\n");
//            stringBuilder.append("}\n");
//            stringBuilder.append(genericFragmentSource);
        } else {
            final String samplerName = shaderType == ShaderType.OES ? "samplerExternalOES" : "sampler2D";
            stringBuilder.append("uniform ").append(samplerName).append(" tex;\n");

            // Update the sampling function in-place.
            stringBuilder.append(genericFragmentSource.replace("sample(", "texture2D(tex, "));
        }
        String ret = stringBuilder.toString();
        Log.d("GLBlurDrawer", "FRAGEMENT: \n"+ret);
        return ret;
    }

//    private final String genericFragmentSource;
//    private final String vertexShader;
    @Nullable
    private ShaderType currentShaderType;
    @Nullable private GlShader currentShader;
    private int inPosLocation;
    private int inTcLocation;
    private int texMatrixLocation;
    private final ShaderCallbacks shaderCallbacks;
    protected float mBlurSize = 3f;
    protected boolean inPixels = true;

    public GLBlurDrawer(ShaderCallbacks shaderCallbacks) {
        this(shaderCallbacks,40f);
    }

    public GLBlurDrawer(ShaderCallbacks shaderCallbacks, float blurSize) {
        this(shaderCallbacks, blurSize, false);
    }

    public GLBlurDrawer(ShaderCallbacks shaderCallbacks, float blurSize, final boolean inPixels) {
        this.shaderCallbacks = shaderCallbacks;
        if (inPixels) {
            setBlurRadiusInPixels(blurSize);
        }
        else
        {
            setBlurSize(blurSize);
        }
    }

    public float getBlurSize() {
        return mBlurSize;
    }

    public float getBlurRadiusInPixels() {
        return mBlurSize;
    }

    /**
     * A multiplier for the blur size, ranging from 0.0 on up, with a default of
     * 1.0
     *
     * @param blurSize
     *            from 0.0 on up, default 1.0
     */
    public void setBlurSize(float blurSize) {
        mBlurSize = blurSize;
        inPixels = false;
    }

    public void setBlurRadiusInPixels(float blurSize) {
        mBlurSize = blurSize;
        inPixels = true;
    }

    // Visible for testing.
    GlShader createShader(ShaderType shaderType) {
        float blurRadiusInPixels = mBlurSize;
        blurRadiusInPixels = Math.round(blurRadiusInPixels);

        int calculatedSampleRadius = 0;
        if (blurRadiusInPixels >= 1) // Avoid a divide-by-zero error here
        {
            // Calculate the number of pixels to sample from by setting a bottom limit for the contribution of the outermost pixel
            float minimumWeightToFindEdgeOfSamplingArea = 1.0f/256.0f;
            calculatedSampleRadius = (int)Math.floor(Math.sqrt(-2.0 * Math.pow(blurRadiusInPixels, 2.0) * Math.log(minimumWeightToFindEdgeOfSamplingArea * Math.sqrt(2.0 * Math.PI * Math.pow(blurRadiusInPixels, 2.0))) ));
            calculatedSampleRadius += calculatedSampleRadius % 2; // There's nothing to gain from handling odd radius sizes, due to the optimizations I use
        }

        String fragment = fragmentShaderForOptimizedBlurOfRadius(shaderType, calculatedSampleRadius, blurRadiusInPixels);
        String vertex = vertexShaderForOptimizedBlurOfRadius(calculatedSampleRadius, blurRadiusInPixels);
        return new GlShader(vertex, fragment);
    }


    private static String vertexShaderForOptimizedBlurOfRadius(final int blurRadius, final float sigma)
    {

        // First, generate the normal Gaussian weights for a given sigma
        float [] standardGaussianWeights = new float[blurRadius + 1];
        float sumOfWeights = 0.0f;
        for (int currentGaussianWeightIndex = 0; currentGaussianWeightIndex < blurRadius + 1; currentGaussianWeightIndex++)
        {
            standardGaussianWeights[currentGaussianWeightIndex] = (float) ((1.0 / Math.sqrt(2.0 * Math.PI * Math.pow(sigma, 2.0))) * Math.exp(-Math.pow(currentGaussianWeightIndex, 2.0) / (2.0 * Math.pow(sigma, 2.0))));

            if (currentGaussianWeightIndex == 0)
            {
                sumOfWeights += standardGaussianWeights[currentGaussianWeightIndex];
            }
            else
            {
                sumOfWeights += 2.0 * standardGaussianWeights[currentGaussianWeightIndex];
            }
        }

        // Next, normalize these weights to prevent the clipping of the Gaussian curve at the end of the discrete samples from reducing luminance
        for (int currentGaussianWeightIndex = 0; currentGaussianWeightIndex < blurRadius + 1; currentGaussianWeightIndex++)
        {
            standardGaussianWeights[currentGaussianWeightIndex] = standardGaussianWeights[currentGaussianWeightIndex] / sumOfWeights;
        }

        // From these weights we calculate the offsets to read interpolated values from
        int numberOfOptimizedOffsets = Math.min(blurRadius / 2 + (blurRadius % 2), 7);
        float [] optimizedGaussianOffsets = new float[numberOfOptimizedOffsets];

        for (int currentOptimizedOffset = 0; currentOptimizedOffset < numberOfOptimizedOffsets; currentOptimizedOffset++)
        {
            float firstWeight = standardGaussianWeights[currentOptimizedOffset*2 + 1];
            float secondWeight = standardGaussianWeights[currentOptimizedOffset*2 + 2];

            float optimizedWeight = firstWeight + secondWeight;

            optimizedGaussianOffsets[currentOptimizedOffset] = (firstWeight * (currentOptimizedOffset*2 + 1) + secondWeight * (currentOptimizedOffset*2 + 2)) / optimizedWeight;
        }

        String shaderString = "attribute vec4 in_pos;\n"
                + "attribute vec4 in_tc;\n"
                + "uniform mat4 tex_mat;\n"
                + "\n"
                + "uniform lowp float texelWidthOffset;\n"
                + "uniform lowp float texelHeightOffset;\n"
                + "\n"
                + "varying vec2 tc;\n"
                + "varying vec2 blurCoordinates[" + (long)(1 + (numberOfOptimizedOffsets * 2)) +"];\n"
                + "\n"
                + "void main()\n"
                + "{\n"
                + "    gl_Position = in_pos;\n"
                + "    tc = (tex_mat * in_tc).xy;\n"
                + "    \n"
                + "    vec2 singleStepOffset = vec2(texelWidthOffset, texelHeightOffset);\n";

        // Inner offset loop
        shaderString += "    blurCoordinates[0] = (tex_mat * in_tc).xy;\n";
        for (int currentOptimizedOffset = 0; currentOptimizedOffset < numberOfOptimizedOffsets; currentOptimizedOffset++)
        {
            shaderString += "    blurCoordinates[" + (long)((currentOptimizedOffset * 2) + 1) + "] = (tex_mat * in_tc).xy + singleStepOffset * " + optimizedGaussianOffsets[currentOptimizedOffset] + ";\n"
                    +  "    blurCoordinates[" + (long)((currentOptimizedOffset * 2) + 2) + "] = (tex_mat * in_tc).xy - singleStepOffset * " + optimizedGaussianOffsets[currentOptimizedOffset] + ";\n";
        }

        // Footer
        shaderString += "}\n";
        return shaderString;
    }
    

    private static String fragmentShaderForOptimizedBlurOfRadius(final ShaderType shaderType, final int blurRadius, final float sigma)
    {
        // First, generate the normal Gaussian weights for a given sigma
        float [] standardGaussianWeights = new float[blurRadius + 1];
        float sumOfWeights = 0.0f;
        for (int currentGaussianWeightIndex = 0; currentGaussianWeightIndex < blurRadius + 1; currentGaussianWeightIndex++)
        {
            standardGaussianWeights[currentGaussianWeightIndex] = (float) ((1.0 / Math.sqrt(2.0 * Math.PI * Math.pow(sigma, 2.0))) * Math.exp(-Math.pow(currentGaussianWeightIndex, 2.0) / (2.0 * Math.pow(sigma, 2.0))));

            if (currentGaussianWeightIndex == 0)
            {
                sumOfWeights += standardGaussianWeights[currentGaussianWeightIndex];
            }
            else
            {
                sumOfWeights += 2.0 * standardGaussianWeights[currentGaussianWeightIndex];
            }
        }

        // Next, normalize these weights to prevent the clipping of the Gaussian curve at the end of the discrete samples from reducing luminance
        for (int currentGaussianWeightIndex = 0; currentGaussianWeightIndex < blurRadius + 1; currentGaussianWeightIndex++)
        {
            standardGaussianWeights[currentGaussianWeightIndex] = standardGaussianWeights[currentGaussianWeightIndex] / sumOfWeights;
        }

        // From these weights we calculate the offsets to read interpolated values from
        int numberOfOptimizedOffsets = Math.min(blurRadius / 2 + (blurRadius % 2), 7);
        int trueNumberOfOptimizedOffsets = blurRadius / 2 + (blurRadius % 2);

        // Header

        final String samplerName = shaderType == ShaderType.OES ? "samplerExternalOES" : "sampler2D";
        String shaderString = "uniform " +samplerName+" tex;\n"
                + "uniform lowp float texelWidthOffset;\n"
                + "uniform lowp float texelHeightOffset;\n"
                + "\n"
                + "varying highp vec2 blurCoordinates[" + (1 + (numberOfOptimizedOffsets * 2)) + "];\n"
                + "varying highp vec2 tc;\n"
                + "\n"
                + "void main()\n"
                + "{\n"
                + "   lowp vec3 sum = vec3(0.0);\n"
                + "   lowp vec4 fragColor=texture2D(tex,tc);\n";

        // Inner texture loop
        shaderString += "    sum += texture2D(tex, blurCoordinates[0]).rgb * " + standardGaussianWeights[0] + ";\n";

        for (int currentBlurCoordinateIndex = 0; currentBlurCoordinateIndex < numberOfOptimizedOffsets; currentBlurCoordinateIndex++)
        {
            float firstWeight = standardGaussianWeights[currentBlurCoordinateIndex * 2 + 1];
            float secondWeight = standardGaussianWeights[currentBlurCoordinateIndex * 2 + 2];
            float optimizedWeight = firstWeight + secondWeight;

            shaderString += "    sum += texture2D(tex, blurCoordinates[" + ((currentBlurCoordinateIndex * 2) + 1) + "]).rgb * " + optimizedWeight + ";\n";
            shaderString += "    sum += texture2D(tex, blurCoordinates[" + ((currentBlurCoordinateIndex * 2) + 2) + "]).rgb * " + optimizedWeight + ";\n";
        }

        // If the number of required samples exceeds the amount we can pass in via varyings, we have to do dependent texture reads in the fragment shader
        if (trueNumberOfOptimizedOffsets > numberOfOptimizedOffsets)
        {
            shaderString += "    highp vec2 singleStepOffset = vec2(texelWidthOffset, texelHeightOffset);\n";
            for (int currentOverlowTextureRead = numberOfOptimizedOffsets; currentOverlowTextureRead < trueNumberOfOptimizedOffsets; currentOverlowTextureRead++)
            {
                float firstWeight = standardGaussianWeights[currentOverlowTextureRead * 2 + 1];
                float secondWeight = standardGaussianWeights[currentOverlowTextureRead * 2 + 2];

                float optimizedWeight = firstWeight + secondWeight;
                float optimizedOffset = (firstWeight * (currentOverlowTextureRead * 2 + 1) + secondWeight * (currentOverlowTextureRead * 2 + 2)) / optimizedWeight;

                shaderString += "    sum += texture2D(tex, blurCoordinates[0] + singleStepOffset * " + optimizedOffset + ").rgb * " + optimizedWeight + ";\n";
                shaderString += "    sum += texture2D(tex, blurCoordinates[0] - singleStepOffset * " + optimizedOffset + ").rgb * " + optimizedWeight + ";\n";
            }
        }

        // Footer
        shaderString += "    gl_FragColor = vec4(sum,fragColor.a);\n"
                + "}\n";
        if (shaderType == ShaderType.OES) {
            shaderString =  "#extension GL_OES_EGL_image_external : require\n" + shaderString;
        }
        return shaderString;
    }
    
    /**
     * Draw an OES texture frame with specified texture transformation matrix. Required resources are
     * allocated at the first call to this function.
     */
    @Override
    public void drawOes(int oesTextureId, float[] texMatrix, int frameWidth, int frameHeight,
                        int viewportX, int viewportY, int viewportWidth, int viewportHeight) {
        prepareShader(
                ShaderType.OES, texMatrix, frameWidth, frameHeight, viewportWidth, viewportHeight);
        // Bind the texture.
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0);
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTextureId);
        // Draw the texture.
        GLES20.glViewport(viewportX, viewportY, viewportWidth, viewportHeight);
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4);
        // Unbind the texture as a precaution.
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, 0);
    }

    /**
     * Draw a RGB(A) texture frame with specified texture transformation matrix. Required resources
     * are allocated at the first call to this function.
     */
    @Override
    public void drawRgb(int textureId, float[] texMatrix, int frameWidth, int frameHeight,
                        int viewportX, int viewportY, int viewportWidth, int viewportHeight) {
        prepareShader(
                ShaderType.RGB, texMatrix, frameWidth, frameHeight, viewportWidth, viewportHeight);

        // Bind the texture.
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0);
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, textureId);

        // Draw the texture.
        GLES20.glViewport(viewportX, viewportY, viewportWidth, viewportHeight);
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4);
        // Unbind the texture as a precaution.
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, 0);
    }

    /**
     * Draw a YUV frame with specified texture transformation matrix. Required resources are allocated
     * at the first call to this function.
     */
    @Override
    public void drawYuv(int[] yuvTextures, float[] texMatrix, int frameWidth, int frameHeight,
                        int viewportX, int viewportY, int viewportWidth, int viewportHeight) {
//        for (int j = 0; j < NUM_PASSES; ++j) {
//            prepareShader(
//                    ShaderType.YUV, texMatrix, frameWidth, frameHeight, viewportWidth, viewportHeight, j == 0);
//            // Bind the textures.
//            for (int i = 0; i < 3; ++i) {
//                GLES20.glActiveTexture(GLES20.GL_TEXTURE0 + i);
//                GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, yuvTextures[i]);
//            }
//            // Draw the textures.
//            GLES20.glViewport(viewportX, viewportY, viewportWidth, viewportHeight);
//            GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4);
//            // Unbind the textures as a precaution.
//            for (int i = 0; i < 3; ++i) {
//                GLES20.glActiveTexture(GLES20.GL_TEXTURE0 + i);
//                GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, 0);
//            }
//        }
    }

    private GlShader allocateShader(ShaderType shaderType, GlShader currentShader, int frameWidth,
                                    int frameHeight) {
        // Allocate new shader.
        if (currentShader != null) {
            currentShader.release();
        }
        GlShader shader = createShader(shaderType);
        shader.useProgram();
        // Set input texture units.
        if (shaderType == ShaderType.YUV) {
            GLES20.glUniform1i(shader.getUniformLocation("y_tex"), 0);
            GLES20.glUniform1i(shader.getUniformLocation("u_tex"), 1);
            GLES20.glUniform1i(shader.getUniformLocation("v_tex"), 2);
        } else {
            GLES20.glUniform1i(shader.getUniformLocation("tex"), 0);
        }
        shaderCallbacks.onNewShader(shader, frameWidth, frameHeight);
        GlUtil.checkNoGLES2Error("Create shader");
        texMatrixLocation = shader.getUniformLocation(TEXTURE_MATRIX_NAME);
        inPosLocation = shader.getAttribLocation(INPUT_VERTEX_COORDINATE_NAME);
        inTcLocation = shader.getAttribLocation(INPUT_TEXTURE_COORDINATE_NAME);
        return shader;
    }

    private void prepareShader(ShaderType shaderType, float[] texMatrix, int frameWidth,
                               int frameHeight, int viewportWidth, int viewportHeight) {
        final GlShader shader;
        if (shaderType.equals(currentShaderType)) {
            shader = currentShader;
        } else {
            currentShader = allocateShader(shaderType, currentShader, frameWidth, frameHeight);
            shader = currentShader;
            currentShaderType = shaderType;
        }
        shader.useProgram();

        // Upload the vertex coordinates.
        GLES20.glEnableVertexAttribArray(inPosLocation);
        GLES20.glVertexAttribPointer(inPosLocation, /* size= */ 2,
                /* type= */ GLES20.GL_FLOAT, /* normalized= */ false, /* stride= */ 0,
                FULL_RECTANGLE_BUFFER);

        // Upload the texture coordinates.
        GLES20.glEnableVertexAttribArray(inTcLocation);
        GLES20.glVertexAttribPointer(inTcLocation, /* size= */ 2,
                /* type= */ GLES20.GL_FLOAT, /* normalized= */ false, /* stride= */ 0,
                FULL_RECTANGLE_TEXTURE_BUFFER);

        // Upload the texture transformation matrix.
        GLES20.glUniformMatrix4fv(
                texMatrixLocation, 1 /* count= */, false /* transpose= */, texMatrix, 0 /* offset= */);

        // Do custom per-frame shader preparation.
        shaderCallbacks.onPrepareShader(
                shader, texMatrix, frameWidth, frameHeight, viewportWidth, viewportHeight);
        GlUtil.checkNoGLES2Error("Prepare shader");
    }

    /**
     * Release all GLES resources. This needs to be done manually, otherwise the resources are leaked.
     */
    @Override
    public void release() {
        if (currentShader != null) {
            currentShader.release();
            currentShader = null;
            currentShaderType = null;
        }
    }
}
