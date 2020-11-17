package com.cloudwebrtc.webrtc;

/*
 *  Copyright 2017 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

import android.content.res.Resources;
import android.graphics.SurfaceTexture;
import android.opengl.GLES20;
import android.util.Log;

import org.webrtc.EglBase;
import org.webrtc.GlRectDrawer;
import org.webrtc.GlShader;
import org.webrtc.Logging;
import org.webrtc.RendererCommon;
import org.webrtc.ThreadUtils;
import org.webrtc.VideoFrame;
import org.webrtc.VideoFrameDrawer;
import org.webrtc.VideoSink;



/**
 * Display the video stream on a Surface.
 * renderFrame() is asynchronous to avoid blocking the calling thread.
 * This class is thread safe and handles access from potentially three different threads:
 * Interaction from the main app in init, release and setMirror.
 * Interaction from C++ rtc::VideoSinkInterface in renderFrame.
 * Interaction from SurfaceHolder lifecycle in surfaceCreated, surfaceChanged, and surfaceDestroyed.
 */
public class SurfaceTextureRenderer extends BlurEglRenderer implements VideoSink {
  private static final String TAG = "SurfaceEglRenderer";
  private VideoFrameDrawer frameDrawer = new VideoFrameDrawer();

  // Callback for reporting renderer events. Read-only after initilization so no lock required.
  private RendererCommon.RendererEvents rendererEvents;

  private final Object layoutLock = new Object();
  private boolean isRenderingPaused = false;
  private boolean isFirstFrameRendered;
  private int rotatedFrameWidth;
  private int rotatedFrameHeight;
  private int frameRotation;
  private SurfaceTexture texture;
  /**
   * In order to render something, you must first call init().
   */
  public SurfaceTextureRenderer(SurfaceTexture texture) {
    super(getResourceName());
    this.texture = texture;
    createEglSurface(texture);
  }

  /**
   * Initialize this class, sharing resources with |sharedContext|. The custom |drawer| will be used
   * for drawing frames on the EGLSurface. This class is responsible for calling release() on
   * |drawer|. It is allowed to call init() to reinitialize the renderer after a previous
   * init()/release() cycle.
   */
  public void init(final EglBase.Context sharedContext,
                   RendererCommon.RendererEvents rendererEvents, final int[] configAttributes,
                   RendererCommon.GlDrawer drawer, GLBlurDrawer first, GLBlurDrawer second) {

    ThreadUtils.checkIsOnMainThread();
    this.rendererEvents = rendererEvents;
    synchronized (layoutLock) {
      isFirstFrameRendered = false;
      rotatedFrameWidth = 0;
      rotatedFrameHeight = 0;
      frameRotation = 0;
    }
    super.init(sharedContext, configAttributes, drawer, first, second);
    createEglSurface(texture);
  }

  public void init(final EglBase.Context sharedContext,
                   RendererCommon.RendererEvents rendererEvents) {
    init(sharedContext, rendererEvents, EglBase.CONFIG_PLAIN, new GlRectDrawer(), new GLBlurDrawer(new BlurShaderCallbacks(true)), new GLBlurDrawer(new BlurShaderCallbacks(false)));
  }

  private static String getResourceName() {
    try {
      return "SurfaceTextureRenderer2: ";
    } catch (Resources.NotFoundException e) {
      return "";
    }
  }

  /**
   * Limit render framerate.
   *
   * @param fps Limit render framerate to this value, or use Float.POSITIVE_INFINITY to disable fps
   *            reduction.
   */
  @Override
  public void setFpsReduction(float fps) {
    synchronized (layoutLock) {
      isRenderingPaused = fps == 0f;
    }
    super.setFpsReduction(fps);
  }

  @Override
  public void disableFpsReduction() {
    synchronized (layoutLock) {
      isRenderingPaused = false;
    }
    super.disableFpsReduction();
  }

  @Override
  public void pauseVideo() {
    synchronized (layoutLock) {
      isRenderingPaused = true;
    }
    super.pauseVideo();
  }

  public void surfaceCreated(final SurfaceTexture texture) {
    ThreadUtils.checkIsOnMainThread();
    this.texture = texture;
    createEglSurface(texture);
  }

  // VideoSink interface.
  @Override
  public void onFrame(VideoFrame frame) {
    updateFrameDimensionsAndReportEvents(frame);
    super.onFrame(frame);
  }


  // Update frame dimensions and report any changes to |rendererEvents|.
  private void updateFrameDimensionsAndReportEvents(VideoFrame frame) {
    synchronized (layoutLock) {
      if (isRenderingPaused) {
        return;
      }
      if (!isFirstFrameRendered) {
        isFirstFrameRendered = true;
        logD("Reporting first rendered frame.");
        if (rendererEvents != null) {
          rendererEvents.onFirstFrameRendered();
        }
      }
      if (rotatedFrameWidth != frame.getRotatedWidth()
              || rotatedFrameHeight != frame.getRotatedHeight()
              || frameRotation != frame.getRotation()) {
        logD("Reporting frame resolution changed to " + frame.getBuffer().getWidth() + "x"
                + frame.getBuffer().getHeight() + " with rotation " + frame.getRotation());
        if (rendererEvents != null) {
          rendererEvents.onFrameResolutionChanged(
                  frame.getBuffer().getWidth(), frame.getBuffer().getHeight(), frame.getRotation());
        }
        rotatedFrameWidth = frame.getRotatedWidth();
        rotatedFrameHeight = frame.getRotatedHeight();
        frameRotation = frame.getRotation();
        texture.setDefaultBufferSize(rotatedFrameWidth, rotatedFrameHeight);
      }
    }
  }

  private void logD(String string) {
    Logging.d(TAG, name + ": " + string);
  }

  private static class BlurShaderCallbacks implements GLBlurDrawer.ShaderCallbacks {
    private final boolean firstPass;
    private int texelWidthLocation;
    private int texelHeightLocation;
    private int width;
    private int height;
    private BlurShaderCallbacks(boolean firstPass) {
      this.firstPass = firstPass;
    }

    public void onNewShader(GlShader shader, int frameWidth, int frameHeight) {
      texelWidthLocation = shader.getUniformLocation(GLBlurDrawer.TEXEL_WIDTH_OFFSET_NAME);
      texelHeightLocation = shader.getUniformLocation(GLBlurDrawer.TEXEL_HEIGHT_OFFSET_NAME);
      this.width = frameWidth;
      this.height = frameHeight;
      setUniform();
    }

    public float getVerticalTexelOffsetRatio() {
      return 1f;
    }

    public float getHorizontalTexelOffsetRatio() {
      return 1f;
    }


    public void onPrepareShader(GlShader shader, float[] texMatrix, int frameWidth, int frameHeight, int viewportWidth, int viewportHeight) {
      if (this.width != frameWidth || this.height != frameHeight) {
        this.width = frameWidth;
        this.height = frameHeight;
        setUniform();
      }
    }

    private void setUniform() {
      if (firstPass) {
        float ratio = getHorizontalTexelOffsetRatio();
        GLES20.glUniform1f(texelWidthLocation,  ratio / width);
        GLES20.glUniform1f(texelHeightLocation, 0);
        Log.d("GLBlurDrawer", "HORIZONTAL WIDTH OFFSET: "+(ratio / width)+"\n");
      } else {
        float ratio = getVerticalTexelOffsetRatio();
        GLES20.glUniform1f(texelWidthLocation,  0);
        GLES20.glUniform1f(texelHeightLocation, ratio / height);
        Log.d("GLBlurDrawer", "VERTICAL HEIGHT OFFSET: "+(ratio / height)+"\n");
      }
    }
  }
}