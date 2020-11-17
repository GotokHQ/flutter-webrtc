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
class GLBlurDrawer2 implements RendererCommon.GlDrawer {
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
            + "  gl_FragColor = vec4(sum,fragColor.a);\n"
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
                    + "  gl_FragColor = vec4(sum,fragColor.a);\n"
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
        void onNewShader(GlShader shader);

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
    private static final String TEXEL_WIDTH_OFFSET_NAME = "texelWidthOffset";
    private static final String TEXEL_HEIGHT_OFFSET_NAME = "texelHeightOffset";
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
            + "  // Calculate the positions for the blur\n"
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
            stringBuilder.append("uniform sampler2D y_tex;\n");
            stringBuilder.append("uniform sampler2D u_tex;\n");
            stringBuilder.append("uniform sampler2D v_tex;\n");

            // Add separate function for sampling texture.
            // yuv_to_rgb_mat is inverse of the matrix defined in YuvConverter.
            stringBuilder.append("vec4 sample(vec2 p) {\n");
            stringBuilder.append("  float y = texture2D(y_tex, p).r * 1.16438;\n");
            stringBuilder.append("  float u = texture2D(u_tex, p).r;\n");
            stringBuilder.append("  float v = texture2D(v_tex, p).r;\n");
            stringBuilder.append("  return vec4(y + 1.59603 * v - 0.874202,\n");
            stringBuilder.append("    y - 0.391762 * u - 0.812968 * v + 0.531668,\n");
            stringBuilder.append("    y + 2.01723 * u - 1.08563, 1);\n");
            stringBuilder.append("}\n");

            stringBuilder.append("vec4 sample2(vec2 p) {\n");
            stringBuilder.append("  float r = coeffs.a + dot(coeffs.rgb, sample(p - 1.5 * xUnit).rgb);\n");
            stringBuilder.append("  float g = coeffs.a + dot(coeffs.rgb, sample(p - 0.5 * xUnit).rgb);\n");
            stringBuilder.append("  float b = coeffs.a + dot(coeffs.rgb, sample(p + 0.5 * xUnit).rgb);\n");
            stringBuilder.append("  float a = coeffs.a + dot(coeffs.rgb, sample(p + 1.5 * xUnit).rgb)\n");
            stringBuilder.append("  return vec4(r, g, b, a);\n");
            stringBuilder.append("}\n");
            stringBuilder.append(genericFragmentSource);
        } else {
            final String samplerName = shaderType == ShaderType.OES ? "samplerExternalOES" : "sampler2D";
            stringBuilder.append("uniform ").append(samplerName).append(" tex;\n");

            // Update the sampling function in-place.
            stringBuilder.append(genericFragmentSource.replace("sample(", "texture2D(tex, "));
        }

        return stringBuilder.toString();
    }

    private final String genericFragmentSource;
    private final String vertexShader;
    @Nullable
    private ShaderType currentShaderType;
    @Nullable private GlShader currentShader;
    private int inPosLocation;
    private int inTcLocation;
    private int texMatrixLocation;

    public GLBlurDrawer2() {
        this(DEFAULT_VERTEX_SHADER_STRING, FRAGMENT_SHADER);
    }

    public GLBlurDrawer2(
            String vertexShader, String genericFragmentSource) {
        this.vertexShader = vertexShader;
        this.genericFragmentSource = genericFragmentSource;
    }

    // Visible for testing.
    GlShader createShader(ShaderType shaderType) {
        return new GlShader(
                vertexShader, createFragmentShaderString(genericFragmentSource, shaderType));
    }

    /**
     * Draw an OES texture frame with specified texture transformation matrix. Required resources are
     * allocated at the first call to this function.
     */
    @Override
    public void drawOes(int oesTextureId, float[] texMatrix, int frameWidth, int frameHeight,
                        int viewportX, int viewportY, int viewportWidth, int viewportHeight) {
        for (int i = 0; i < NUM_PASSES; ++i) {
            prepareShader(
                    ShaderType.OES, texMatrix, frameWidth, frameHeight, viewportWidth, viewportHeight, i == 0);
            // Bind the texture.
            GLES20.glActiveTexture(GLES20.GL_TEXTURE0);
            GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTextureId);
            // Draw the texture.
            GLES20.glViewport(viewportX, viewportY, viewportWidth, viewportHeight);
            GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4);
            // Unbind the texture as a precaution.
            GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, 0);
        }
    }

    /**
     * Draw a RGB(A) texture frame with specified texture transformation matrix. Required resources
     * are allocated at the first call to this function.
     */
    @Override
    public void drawRgb(int textureId, float[] texMatrix, int frameWidth, int frameHeight,
                        int viewportX, int viewportY, int viewportWidth, int viewportHeight) {
        for (int i = 0; i < NUM_PASSES; ++i) {
            prepareShader(
                    ShaderType.RGB, texMatrix, frameWidth, frameHeight, viewportWidth, viewportHeight, i == 0);
            // Bind the texture.
            GLES20.glActiveTexture(GLES20.GL_TEXTURE0);
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, textureId);
            // Draw the texture.
            GLES20.glViewport(viewportX, viewportY, viewportWidth, viewportHeight);
            GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4);
            // Unbind the texture as a precaution.
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, 0);
        }
    }

    /**
     * Draw a YUV frame with specified texture transformation matrix. Required resources are allocated
     * at the first call to this function.
     */
    @Override
    public void drawYuv(int[] yuvTextures, float[] texMatrix, int frameWidth, int frameHeight,
                        int viewportX, int viewportY, int viewportWidth, int viewportHeight) {
        for (int j = 0; j < NUM_PASSES; ++j) {
            prepareShader(
                    ShaderType.YUV, texMatrix, frameWidth, frameHeight, viewportWidth, viewportHeight, j == 0);
            // Bind the textures.
            for (int i = 0; i < 3; ++i) {
                GLES20.glActiveTexture(GLES20.GL_TEXTURE0 + i);
                GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, yuvTextures[i]);
            }
            // Draw the textures.
            GLES20.glViewport(viewportX, viewportY, viewportWidth, viewportHeight);
            GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4);
            // Unbind the textures as a precaution.
            for (int i = 0; i < 3; ++i) {
                GLES20.glActiveTexture(GLES20.GL_TEXTURE0 + i);
                GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, 0);
            }
        }
    }

    private void prepareShader(ShaderType shaderType, float[] texMatrix, int frameWidth,
                               int frameHeight, int viewportWidth, int viewportHeight, boolean firstPass) {
        final GlShader shader;
        if (shaderType.equals(currentShaderType)) {
            // Same shader type as before, reuse exising shader.
            shader = currentShader;
        } else {
            // Allocate new shader.
            currentShaderType = shaderType;
            if (currentShader != null) {
                currentShader.release();
            }
            shader = createShader(shaderType);
            currentShader = shader;

            shader.useProgram();
            // Set input texture units.
            if (shaderType == ShaderType.YUV) {
                GLES20.glUniform1i(shader.getUniformLocation("y_tex"), 0);
                GLES20.glUniform1i(shader.getUniformLocation("u_tex"), 1);
                GLES20.glUniform1i(shader.getUniformLocation("v_tex"), 2);
            } else {
                GLES20.glUniform1i(shader.getUniformLocation("tex"), 0);
            }
            if (firstPass) {
                float ratio = getHorizontalTexelOffsetRatio();
                GLES20.glUniform1f(shader.getUniformLocation(TEXEL_WIDTH_OFFSET_NAME),  ratio / frameWidth);
                GLES20.glUniform1f(shader.getUniformLocation(TEXEL_HEIGHT_OFFSET_NAME), 0);
            } else {
                float ratio = getVerticalTexelOffsetRatio();
                GLES20.glUniform1f(shader.getUniformLocation(TEXEL_HEIGHT_OFFSET_NAME),  0);
                GLES20.glUniform1f(shader.getUniformLocation(TEXEL_WIDTH_OFFSET_NAME), ratio / frameHeight);
            }

            GlUtil.checkNoGLES2Error("Create shader");
            //shaderCallbacks.onNewShader(shader);
            texMatrixLocation = shader.getUniformLocation(TEXTURE_MATRIX_NAME);
            inPosLocation = shader.getAttribLocation(INPUT_VERTEX_COORDINATE_NAME);
            inTcLocation = shader.getAttribLocation(INPUT_TEXTURE_COORDINATE_NAME);
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

        GlUtil.checkNoGLES2Error("Prepare shader");
    }


    public float getVerticalTexelOffsetRatio() {
        return 1f;
    }

    public float getHorizontalTexelOffsetRatio() {
        return 1f;
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
