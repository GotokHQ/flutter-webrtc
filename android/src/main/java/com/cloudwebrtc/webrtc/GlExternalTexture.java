package com.cloudwebrtc.webrtc;

import android.opengl.GLES11Ext;
import android.opengl.GLES20;

import org.webrtc.GlUtil;

public class GlExternalTexture {
    private int textureId;
    private int width;
    private int height;

    /**
     * Generate texture and framebuffer resources. An EGLContext must be bound on the current thread
     * when calling this function. The framebuffer is not complete until setSize() is called.
     */
    public GlExternalTexture() {
        this.width = 0;
        this.height = 0;
    }

    /**
     * (Re)allocate texture. Will do nothing if the requested size equals the current size. An
     * EGLContext must be bound on the current thread when calling this function. Must be called at
     * least once before using the framebuffer. May be called multiple times to change size.
     */
    public void setSize(int width, int height) {
        if (width <= 0 || height <= 0) {
            throw new IllegalArgumentException("Invalid size: " + width + "x" + height);
        }
        if (width == this.width && height == this.height) {
            return;
        }
        this.width = width;
        this.height = height;
        // Lazy allocation the first time setSize() is called.
        if (textureId == 0) {
            textureId = GlUtil.generateTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES);
        }
    }

    public int getWidth() {
        return width;
    }

    public int getHeight() {
        return height;
    }

    public int getTextureId() {
        return  textureId;
    }
    /**
     * Release texture and framebuffer. An EGLContext must be bound on the current thread when calling
     * this function. This object should not be used after this call.
     */
    public void release() {
        GLES20.glDeleteTextures(1, new int[] {textureId}, 0);
        textureId = 0;
        width = 0;
        height = 0;
    }
}
