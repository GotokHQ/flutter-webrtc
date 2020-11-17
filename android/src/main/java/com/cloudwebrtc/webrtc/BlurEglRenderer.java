package com.cloudwebrtc.webrtc;

/*
 *  Copyright 2016 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */


import android.graphics.Matrix;
import android.graphics.Point;
import android.graphics.SurfaceTexture;
import android.opengl.GLES20;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.Looper;
import android.os.Message;
import android.view.Surface;

import androidx.annotation.Nullable;

import org.webrtc.EglBase;
import org.webrtc.GlRectDrawer;
import org.webrtc.GlTextureFrameBuffer;
import org.webrtc.GlUtil;
import org.webrtc.Logging;
import org.webrtc.RendererCommon;
import org.webrtc.ThreadUtils;
import org.webrtc.VideoFrame;
import org.webrtc.VideoFrameDrawer;
import org.webrtc.VideoSink;

import java.nio.ByteBuffer;
import java.text.DecimalFormat;
import java.util.ArrayList;
import java.util.Iterator;
import java.util.Optional;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/**
 * Implements VideoSink by displaying the video stream on an EGL Surface. This class is intended to
 * be used as a helper class for rendering on SurfaceViews and TextureViews.
 */
public class BlurEglRenderer implements VideoSink {
    private static final String TAG = "BlurEglRenderer";
    private static final long LOG_INTERVAL_SEC = 4;

    public interface FrameListener {
        int getId();
        int getWidth();
        int getHeight();
        ByteBuffer getBuffer();
        void onFrame(ByteBuffer buffer); }

    /** Callback for clients to be notified about errors encountered during rendering. */
    public static interface ErrorCallback {
        /** Called if GLES20.GL_OUT_OF_MEMORY is encountered during rendering. */
        void onGlOutOfMemory();
    }

    private static class FrameListenerAndParams {
        public final FrameListener listener;
        public final float scale;
        public final RendererCommon.GlDrawer drawer;
        public final boolean applyFpsReduction;

        public FrameListenerAndParams(FrameListener listener) {
            this(listener, 1.0f, null, false);
        }

        public FrameListenerAndParams(FrameListener listener,
                                      RendererCommon.GlDrawer drawer, boolean applyFpsReduction) {
            this(listener, 1.0f, drawer, applyFpsReduction);
        }

        public FrameListenerAndParams(FrameListener listener, float scale,
                                      RendererCommon.GlDrawer drawer, boolean applyFpsReduction) {
            this.listener = listener;
            this.scale = scale;
            this.drawer = drawer;
            this.applyFpsReduction = applyFpsReduction;
        }
    }

    private class EglSurfaceCreation implements Runnable {
        private Object surface;

        // TODO(bugs.webrtc.org/8491): Remove NoSynchronizedMethodCheck suppression.
        @SuppressWarnings("NoSynchronizedMethodCheck")
        public synchronized void setSurface(Object surface) {
            this.surface = surface;
        }

        @Override
        // TODO(bugs.webrtc.org/8491): Remove NoSynchronizedMethodCheck suppression.
        @SuppressWarnings("NoSynchronizedMethodCheck")
        public synchronized void run() {
            if (surface != null && eglBase != null && !eglBase.hasSurface()) {
                if (surface instanceof Surface) {
                    eglBase.createSurface((Surface) surface);
                } else if (surface instanceof SurfaceTexture) {
                    eglBase.createSurface((SurfaceTexture) surface);
                } else {
                    throw new IllegalStateException("Invalid surface: " + surface);
                }
                eglBase.makeCurrent();
                // Necessary for YUV frames with odd width.
                GLES20.glPixelStorei(GLES20.GL_UNPACK_ALIGNMENT, 1);
            }
        }
    }

    /**
     * Handler that triggers a callback when an uncaught exception happens when handling a message.
     */
    private static class HandlerWithExceptionCallback extends Handler {
        private final Runnable exceptionCallback;

        public HandlerWithExceptionCallback(Looper looper, Runnable exceptionCallback) {
            super(looper);
            this.exceptionCallback = exceptionCallback;
        }

        @Override
        public void dispatchMessage(Message msg) {
            try {
                super.dispatchMessage(msg);
            } catch (Exception e) {
                Logging.e(TAG, "Exception on BlurEglRenderer thread", e);
                exceptionCallback.run();
                throw e;
            }
        }
    }

    protected final String name;

    // |renderThreadHandler| is a handler for communicating with |renderThread|, and is synchronized
    // on |handlerLock|.
    private final Object handlerLock = new Object();
    @Nullable private Handler renderThreadHandler;

    private final ArrayList<FrameListenerAndParams> frameListeners = new ArrayList<>();

    private volatile ErrorCallback errorCallback;

    // Variables for fps reduction.
    private final Object fpsReductionLock = new Object();
    // Time for when next frame should be rendered.
    private long nextFrameTimeNs;
    // Minimum duration between frames when fps reduction is active, or -1 if video is completely
    // paused.
    private long minRenderPeriodNs;

    // EGL and GL resources for drawing YUV/OES textures. After initialization, these are only
    // accessed from the render thread.
    @Nullable
    private EglBase eglBase;
    private final VideoFrameDrawer frameDrawer;
    @Nullable private RendererCommon.GlDrawer drawer;
    @Nullable private RendererCommon.GlDrawer passThroughDrawer = new GlRectDrawer();
    @Nullable private RendererCommon.GlDrawer bitmapDrawer = new GlRectDrawer();
    @Nullable private GLBlurDrawer firstPassBlurDrawer;
    @Nullable private GLBlurDrawer secondPassBlurDrawer;
    private boolean usePresentationTimeStamp;
    private final Matrix drawMatrix = new Matrix();

    // Pending frame to render. Serves as a queue with size 1. Synchronized on |frameLock|.
    private final Object frameLock = new Object();
    @Nullable private VideoFrame pendingFrame;

    // These variables are synchronized on |layoutLock|.
    private final Object layoutLock = new Object();
    private float layoutAspectRatio;
    // If true, mirrors the video stream horizontally.
    private boolean mirrorHorizontally;
    // If true, mirrors the video stream vertically.
    private boolean mirrorVertically;

    // These variables are synchronized on |statisticsLock|.
    private final Object statisticsLock = new Object();
    // Total number of video frames received in renderFrame() call.
    private int framesReceived;
    // Number of video frames dropped by renderFrame() because previous frame has not been rendered
    // yet.
    private int framesDropped;
    // Number of rendered video frames.
    private int framesRendered;
    // Start time for counting these statistics, or 0 if we haven't started measuring yet.
    private long statisticsStartTimeNs;
    // Time in ns spent in renderFrameOnRenderThread() function.
    private long renderTimeNs;
    // Time in ns spent by the render thread in the swapBuffers() function.
    private long renderSwapBufferTimeNs;

    private final Object blurLock = new Object();
    private boolean blur;

    private GlTextureFrameBuffer firstTextureFramebuffer =
            new GlTextureFrameBuffer(GLES20.GL_RGBA);

    private GlTextureFrameBuffer secondTextureFramebuffer =
            new GlTextureFrameBuffer(GLES20.GL_RGBA);

    private GlTextureFrameBuffer bitmapTextureFramebuffer =
            new GlTextureFrameBuffer(GLES20.GL_RGBA);

    private GlTextureFrameBuffer snapshotTextureFramebuffer =
            new GlTextureFrameBuffer(GLES20.GL_RGBA);

    // clang-format off
    private static final float[] IDENTITY_MATRIX = {
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1};
    // clang-format on

    private final Runnable logStatisticsRunnable = new Runnable() {
        @Override
        public void run() {
            logStatistics();
            synchronized (handlerLock) {
                if (renderThreadHandler != null) {
                    renderThreadHandler.removeCallbacks(logStatisticsRunnable);
                    renderThreadHandler.postDelayed(
                            logStatisticsRunnable, TimeUnit.SECONDS.toMillis(LOG_INTERVAL_SEC));
                }
            }
        }
    };

    private final EglSurfaceCreation eglSurfaceCreationRunnable = new EglSurfaceCreation();

    /**
     * Standard constructor. The name will be used for the render thread name and included when
     * logging. In order to render something, you must first call init() and createEglSurface.
     */
    public BlurEglRenderer(String name) {
        this(name, new VideoFrameDrawer());
    }

    public BlurEglRenderer(String name, VideoFrameDrawer videoFrameDrawer) {
        this.name = name;
        this.frameDrawer = videoFrameDrawer;
    }

    /**
     * Initialize this class, sharing resources with |sharedContext|. The custom |drawer| will be used
     * for drawing frames on the EGLSurface. This class is responsible for calling release() on
     * |drawer|. It is allowed to call init() to reinitialize the renderer after a previous
     * init()/release() cycle. If usePresentationTimeStamp is true, eglPresentationTimeANDROID will be
     * set with the frame timestamps, which specifies desired presentation time and might be useful
     * for e.g. syncing audio and video.
     */
    public void init(@Nullable final EglBase.Context sharedContext, final int[] configAttributes,
                     RendererCommon.GlDrawer drawer, GLBlurDrawer firstPassBlurDrawer, GLBlurDrawer secondPassBlurDrawer, boolean usePresentationTimeStamp) {
        synchronized (handlerLock) {
            if (renderThreadHandler != null) {
                throw new IllegalStateException(name + "Already initialized");
            }
            logD("Initializing BlurEglRenderer");
            this.drawer = drawer;
            this.usePresentationTimeStamp = usePresentationTimeStamp;
            this.firstPassBlurDrawer = firstPassBlurDrawer;
            this.secondPassBlurDrawer = secondPassBlurDrawer;
            if (this.firstTextureFramebuffer != null) {
                this.firstTextureFramebuffer.release();
            }
            this.firstTextureFramebuffer = new GlTextureFrameBuffer(GLES20.GL_RGBA);
            if (this.secondTextureFramebuffer != null) {
                this.secondTextureFramebuffer.release();
            }
            this.secondTextureFramebuffer = new GlTextureFrameBuffer(GLES20.GL_RGBA);
            if (this.bitmapTextureFramebuffer != null) {
                this.bitmapTextureFramebuffer.release();
            }
            this.bitmapTextureFramebuffer = new GlTextureFrameBuffer(GLES20.GL_RGBA);
            if (this.snapshotTextureFramebuffer != null) {
                this.snapshotTextureFramebuffer.release();
            }
            this.snapshotTextureFramebuffer = new GlTextureFrameBuffer(GLES20.GL_RGBA);

            final HandlerThread renderThread = new HandlerThread(name + "BlurEglRenderer");
            renderThread.start();
            renderThreadHandler =
                    new HandlerWithExceptionCallback(renderThread.getLooper(), new Runnable() {
                        @Override
                        public void run() {
                            synchronized (handlerLock) {
                                renderThreadHandler = null;
                            }
                        }
                    });
            // Create EGL context on the newly created render thread. It should be possibly to create the
            // context on this thread and make it current on the render thread, but this causes failure on
            // some Marvel based JB devices. https://bugs.chromium.org/p/webrtc/issues/detail?id=6350.
            ThreadUtils.invokeAtFrontUninterruptibly(renderThreadHandler, () -> {
                logD("EglBase.create shared context");
                eglBase = EglBase.create(sharedContext, configAttributes);
            });
            renderThreadHandler.post(eglSurfaceCreationRunnable);
            final long currentTimeNs = System.nanoTime();
            resetStatistics(currentTimeNs);
//            renderThreadHandler.postDelayed(
//                    logStatisticsRunnable, TimeUnit.SECONDS.toMillis(LOG_INTERVAL_SEC));
        }
    }

    /**
     * Same as above with usePresentationTimeStamp set to false.
     *
     * @see #init(EglBase.Context, int[], RendererCommon.GlDrawer, GLBlurDrawer, GLBlurDrawer)
     */
    public void init(@Nullable final EglBase.Context sharedContext, final int[] configAttributes,
                     RendererCommon.GlDrawer drawer, GLBlurDrawer firstPassBlurDrawer, GLBlurDrawer secondPassBlurDrawer) {
        init(sharedContext, configAttributes, drawer, firstPassBlurDrawer, secondPassBlurDrawer, /* usePresentationTimeStamp= */ false);
    }

    public void createEglSurface(Surface surface) {
        createEglSurfaceInternal(surface);
    }

    public void createEglSurface(SurfaceTexture surfaceTexture) {
        createEglSurfaceInternal(surfaceTexture);
    }

    private void createEglSurfaceInternal(Object surface) {
        eglSurfaceCreationRunnable.setSurface(surface);
        postToRenderThread(eglSurfaceCreationRunnable);
    }

    /**
     * Block until any pending frame is returned and all GL resources released, even if an interrupt
     * occurs. If an interrupt occurs during release(), the interrupt flag will be set. This function
     * should be called before the Activity is destroyed and the EGLContext is still valid. If you
     * don't call this function, the GL resources might leak.
     */
    public void release() {
        logD("Releasing.");
        final CountDownLatch eglCleanupBarrier = new CountDownLatch(1);
        synchronized (handlerLock) {
            if (renderThreadHandler == null) {
                logD("Already released");
                return;
            }
            renderThreadHandler.removeCallbacks(logStatisticsRunnable);
            // Release EGL and GL resources on render thread.
            renderThreadHandler.postAtFrontOfQueue(() -> {
                // Detach current shader program.
                GLES20.glUseProgram(/* program= */ 0);
                if (drawer != null) {
                    drawer.release();
                    drawer = null;
                }
                if (passThroughDrawer != null) {
                    passThroughDrawer.release();
                    passThroughDrawer = null;
                }
                if (bitmapDrawer != null) {
                    bitmapDrawer.release();
                    bitmapDrawer = null;
                }
                if (firstPassBlurDrawer != null) {
                    firstPassBlurDrawer.release();
                    firstPassBlurDrawer = null;
                }
                if (secondPassBlurDrawer != null) {
                    secondPassBlurDrawer.release();
                    secondPassBlurDrawer = null;
                }
                frameDrawer.release();
                bitmapTextureFramebuffer.release();
                bitmapTextureFramebuffer = null;
                snapshotTextureFramebuffer.release();
                snapshotTextureFramebuffer = null;
                firstTextureFramebuffer.release();
                firstTextureFramebuffer = null;
                secondTextureFramebuffer.release();
                secondTextureFramebuffer = null;

                this.bitmapTextureFramebuffer = new GlTextureFrameBuffer(GLES20.GL_RGBA);
                if (this.snapshotTextureFramebuffer != null) {
                    this.snapshotTextureFramebuffer.release();
                }
                this.snapshotTextureFramebuffer = new GlTextureFrameBuffer(GLES20.GL_RGBA);

                if (eglBase != null) {
                    logD("eglBase detach and release.");
                    eglBase.detachCurrent();
                    eglBase.release();
                    eglBase = null;
                }
                frameListeners.clear();
                eglCleanupBarrier.countDown();
            });
            final Looper renderLooper = renderThreadHandler.getLooper();
            // TODO(magjed): Replace this post() with renderLooper.quitSafely() when API support >= 18.
            renderThreadHandler.post(() -> {
                logD("Quitting render thread.");
                renderLooper.quit();
            });
            // Don't accept any more frames or messages to the render thread.
            renderThreadHandler = null;
        }
        // Make sure the EGL/GL cleanup posted above is executed.
        ThreadUtils.awaitUninterruptibly(eglCleanupBarrier);
        synchronized (frameLock) {
            if (pendingFrame != null) {
                pendingFrame.release();
                pendingFrame = null;
            }
        }
        logD("Releasing done.");
    }

    /**
     * Reset the statistics logged in logStatistics().
     */
    private void resetStatistics(long currentTimeNs) {
        synchronized (statisticsLock) {
            statisticsStartTimeNs = currentTimeNs;
            framesReceived = 0;
            framesDropped = 0;
            framesRendered = 0;
            renderTimeNs = 0;
            renderSwapBufferTimeNs = 0;
        }
    }

    public void printStackTrace() {
        synchronized (handlerLock) {
            final Thread renderThread =
                    (renderThreadHandler == null) ? null : renderThreadHandler.getLooper().getThread();
            if (renderThread != null) {
                final StackTraceElement[] renderStackTrace = renderThread.getStackTrace();
                if (renderStackTrace.length > 0) {
                    logW("BlurEglRenderer stack trace:");
                    for (StackTraceElement traceElem : renderStackTrace) {
                        logW(traceElem.toString());
                    }
                }
            }
        }
    }

    /**
     * Set if the video stream should blurred or not.
     */
    public void setBlur(final boolean blur) {
        logD("setBlur: " + blur);
        synchronized (blurLock) {
            this.blur = blur;
        }
    }

    /**
     * Set if the video stream should be mirrored horizontally or not.
     */
    public void setMirror(final boolean mirror) {
        logD("setMirrorHorizontally: " + mirror);
        synchronized (layoutLock) {
            this.mirrorHorizontally = mirror;
        }
    }

    /**
     * Set if the video stream should be mirrored vertically or not.
     */
    public void setMirrorVertically(final boolean mirrorVertically) {
        logD("setMirrorVertically: " + mirrorVertically);
        synchronized (layoutLock) {
            this.mirrorVertically = mirrorVertically;
        }
    }

    /**
     * Set layout aspect ratio. This is used to crop frames when rendering to avoid stretched video.
     * Set this to 0 to disable cropping.
     */
    public void setLayoutAspectRatio(float layoutAspectRatio) {
        logD("setLayoutAspectRatio: " + layoutAspectRatio);
        synchronized (layoutLock) {
            this.layoutAspectRatio = layoutAspectRatio;
        }
    }

    /**
     * Limit render framerate.
     *
     * @param fps Limit render framerate to this value, or use Float.POSITIVE_INFINITY to disable fps
     *            reduction.
     */
    public void setFpsReduction(float fps) {
        logD("setFpsReduction: " + fps);
        synchronized (fpsReductionLock) {
            final long previousRenderPeriodNs = minRenderPeriodNs;
            if (fps <= 0) {
                minRenderPeriodNs = Long.MAX_VALUE;
            } else {
                minRenderPeriodNs = (long) (TimeUnit.SECONDS.toNanos(1) / fps);
            }
            if (minRenderPeriodNs != previousRenderPeriodNs) {
                // Fps reduction changed - reset frame time.
                nextFrameTimeNs = System.nanoTime();
            }
        }
    }

    public void disableFpsReduction() {
        setFpsReduction(Float.POSITIVE_INFINITY /* fps */);
    }

    public void pauseVideo() {
        setFpsReduction(0 /* fps */);
    }

    /**
     * Register a callback to be invoked when a new video frame has been received. This version uses
     * the drawer of the BlurEglRenderer that was passed in init.
     *
     * @param listener The callback to be invoked. The callback will be invoked on the render thread.
     *                 It should be lightweight and must not call removeFrameListener.
     */
    public void addFrameListener(final FrameListener listener) {
        addFrameListener(listener, 1.0f, null, false);
    }

    /**
     * Register a callback to be invoked when a new video frame has been received. This version uses
     * the drawer of the BlurEglRenderer that was passed in init.
     *
     * @param listener The callback to be invoked. The callback will be invoked on the render thread.
     *                 It should be lightweight and must not call removeFrameListener.
     * @param scale    The scale of the Bitmap passed to the callback, or 0 if no Bitmap is
     *                 required.
     */
    public void addFrameListener(final FrameListener listener, final float scale) {
        addFrameListener(listener, scale, null, false /* applyFpsReduction */);
    }

    /**
     * Register a callback to be invoked when a new video frame has been received.
     *
     * @param listener The callback to be invoked. The callback will be invoked on the render thread.
     *                 It should be lightweight and must not call removeFrameListener.
     * @param scale    The scale of the Bitmap passed to the callback, or 0 if no Bitmap is
     *                 required.
     * @param drawerParam   Custom drawer to use for this frame listener or null to use the default one.
     */
    public void addFrameListener(
            final FrameListener listener, final float scale, final RendererCommon.GlDrawer drawerParam) {
        addFrameListener(listener, scale, drawerParam, false /* applyFpsReduction */);
    }

    /**
     * Register a callback to be invoked when a new video frame has been received.
     *
     * @param listener The callback to be invoked. The callback will be invoked on the render thread.
     *                 It should be lightweight and must not call removeFrameListener.
     * @param scale    The scale of the Bitmap passed to the callback, or 0 if no Bitmap is
     *                 required.
     * @param drawerParam   Custom drawer to use for this frame listener or null to use the default one.
     * @param applyFpsReduction This callback will not be called for frames that have been dropped by
     *                          FPS reduction.
     */
    public void addFrameListener(final FrameListener listener, final float scale,
                                 @Nullable final RendererCommon.GlDrawer drawerParam, final boolean applyFpsReduction) {
        synchronized (handlerLock) {
            if (renderThreadHandler != null) {
                renderThreadHandler.post(() -> doAddFrame(listener, scale, drawerParam, applyFpsReduction));
            } else {
                doAddFrame(listener, scale, drawerParam, applyFpsReduction);
            }
        }
    }

    void doAddFrame(final FrameListener listener, final float scale,
                    @Nullable final RendererCommon.GlDrawer drawerParam, final boolean applyFpsReduction) {
        final RendererCommon.GlDrawer listenerDrawer = drawerParam == null ? drawer : drawerParam;
        final Optional<FrameListenerAndParams> found = frameListeners.stream().filter(params -> params.listener == listener).findFirst();
        if (!found.isPresent()) {
            frameListeners.add(
                    new FrameListenerAndParams(listener, scale, listenerDrawer, applyFpsReduction));
        }
    }

    /**
     * Register a callback to be invoked when a new video frame has been received.
     *
     * @param listenerAndParams The callback to be invoked. The callback will be invoked on the render thread.
     *                 It should be lightweight and must not call removeFrameListener.
     */
    public void addFrameListenerAndParams(final FrameListenerAndParams listenerAndParams) {
        postToRenderThread(() -> {
            frameListeners.add(listenerAndParams);
        });
    }

    /**
     * Remove any pending callback that was added with addFrameListener. If the callback is not in
     * the queue, nothing happens. It is ensured that callback won't be called after this method
     * returns.
     *
     * @param listener The callback to remove.
     */
    public void removeFrameListener(final FrameListener listener) {
        final CountDownLatch latch = new CountDownLatch(1);
        synchronized (handlerLock) {
            if (renderThreadHandler == null) {
                return;
            }
            if (Thread.currentThread() == renderThreadHandler.getLooper().getThread()) {
                throw new RuntimeException("removeFrameListener must not be called on the render thread.");
            }
            postToRenderThread(() -> {
                latch.countDown();
                final Iterator<FrameListenerAndParams> iter = frameListeners.iterator();
                while (iter.hasNext()) {
                    if (iter.next().listener == listener) {
                        iter.remove();
                    }
                }
            });
        }
        ThreadUtils.awaitUninterruptibly(latch);
    }

    /** Can be set in order to be notified about errors encountered during rendering. */
    public void setErrorCallback(ErrorCallback errorCallback) {
        this.errorCallback = errorCallback;
    }

    // VideoSink interface.
    @Override
    public void onFrame(VideoFrame frame) {
        synchronized (statisticsLock) {
            ++framesReceived;
        }
        final boolean dropOldFrame;
        synchronized (handlerLock) {
            if (renderThreadHandler == null) {
                logD("Dropping frame - Not initialized or already released.");
                return;
            }
            synchronized (frameLock) {
                dropOldFrame = (pendingFrame != null);
                if (dropOldFrame) {
                    pendingFrame.release();
                }
                pendingFrame = frame;
                pendingFrame.retain();
                renderThreadHandler.post(this ::renderFrameOnRenderThread);
            }
        }
        if (dropOldFrame) {
            synchronized (statisticsLock) {
                ++framesDropped;
            }
        }
    }

    /**
     * Release EGL surface. This function will block until the EGL surface is released.
     */
    public void releaseEglSurface(final Runnable completionCallback) {
        // Ensure that the render thread is no longer touching the Surface before returning from this
        // function.
        eglSurfaceCreationRunnable.setSurface(null /* surface */);
        synchronized (handlerLock) {
            if (renderThreadHandler != null) {
                renderThreadHandler.removeCallbacks(eglSurfaceCreationRunnable);
                renderThreadHandler.postAtFrontOfQueue(() -> {
                    if (eglBase != null) {
                        eglBase.detachCurrent();
                        eglBase.releaseSurface();
                    }
                    completionCallback.run();
                });
                return;
            }
        }
        completionCallback.run();
    }

    /**
     * Private helper function to post tasks safely.
     */
    private void postToRenderThread(Runnable runnable) {
        synchronized (handlerLock) {
            if (renderThreadHandler != null) {
                renderThreadHandler.post(runnable);
            }
        }
    }

    private void clearSurfaceOnRenderThread(float r, float g, float b, float a) {
        if (eglBase != null && eglBase.hasSurface()) {
            logD("clearSurface");
            GLES20.glClearColor(r, g, b, a);
            GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT);
            eglBase.swapBuffers();
        }
    }

    /**
     * Post a task to clear the surface to a transparent uniform color.
     */
    public void clearImage() {
        clearImage(0 /* red */, 0 /* green */, 0 /* blue */, 0 /* alpha */);
    }

    /**
     * Post a task to clear the surface to a specific color.
     */
    public void clearImage(final float r, final float g, final float b, final float a) {
        synchronized (handlerLock) {
            if (renderThreadHandler == null) {
                return;
            }
            renderThreadHandler.postAtFrontOfQueue(() -> clearSurfaceOnRenderThread(r, g, b, a));
        }
    }

    /**
     * Renders and releases |pendingFrame|.
     */
    private void renderFrameOnRenderThread() {
        // Fetch and render |pendingFrame|.
        final VideoFrame frame;
        synchronized (frameLock) {
            if (pendingFrame == null) {
                return;
            }
            frame = pendingFrame;
            pendingFrame = null;
        }
        if (eglBase == null || !eglBase.hasSurface()) {
            logD("Dropping frame - No surface");
            frame.release();
            return;
        }
        // Check if fps reduction is active.
        final boolean shouldRenderFrame;
        synchronized (fpsReductionLock) {
            if (minRenderPeriodNs == Long.MAX_VALUE) {
                // Rendering is paused.
                shouldRenderFrame = false;
            } else if (minRenderPeriodNs <= 0) {
                // FPS reduction is disabled.
                shouldRenderFrame = true;
            } else {
                final long currentTimeNs = System.nanoTime();
                if (currentTimeNs < nextFrameTimeNs) {
                    logD("Skipping frame rendering - fps reduction is active.");
                    shouldRenderFrame = false;
                } else {
                    nextFrameTimeNs += minRenderPeriodNs;
                    // The time for the next frame should always be in the future.
                    nextFrameTimeNs = Math.max(nextFrameTimeNs, currentTimeNs);
                    shouldRenderFrame = true;
                }
            }
        }

        final long startTimeNs = System.nanoTime();

        final float frameAspectRatio = frame.getRotatedWidth() / (float) frame.getRotatedHeight();
        final float drawnAspectRatio;
        synchronized (layoutLock) {
            drawnAspectRatio = layoutAspectRatio != 0f ? layoutAspectRatio : frameAspectRatio;
        }

        final float scaleX;
        final float scaleY;

        if (frameAspectRatio > drawnAspectRatio) {
            scaleX = drawnAspectRatio / frameAspectRatio;
            scaleY = 1f;
        } else {
            scaleX = 1f;
            scaleY = frameAspectRatio / drawnAspectRatio;
        }

        drawMatrix.reset();
        drawMatrix.preTranslate(0.5f, 0.5f);
        drawMatrix.preScale(mirrorHorizontally ? -1f : 1f, mirrorVertically ? -1f : 1f);
        drawMatrix.preScale(scaleX, scaleY);
        drawMatrix.preTranslate(-0.5f, -0.5f);

        try {
            if (shouldRenderFrame) {
                snapshotTextureFramebuffer.setSize(frame.getRotatedWidth(), frame.getRotatedHeight());

                GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, snapshotTextureFramebuffer.getFrameBufferId());

                GLES20.glClearColor(0 /* red */, 0 /* green */, 0 /* blue */, 0 /* alpha */);
                GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT);
                frameDrawer.drawFrame(frame, drawer, drawMatrix, 0 /* viewportX */, 0 /* viewportY */,
                        eglBase.surfaceWidth(), eglBase.surfaceHeight());
                GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0);
                GlUtil.checkNoGLES2Error("EglRenderer2.notifyCallbacks");
                if (blur) {
                    secondTextureFramebuffer.setSize(frame.getRotatedWidth(), frame.getRotatedHeight());

                    GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, secondTextureFramebuffer.getFrameBufferId());
                    GlUtil.checkNoGLES2Error("BlurEglRenderer.renderFrameOnRenderThread");

                    firstPassBlurDrawer.drawRgb(snapshotTextureFramebuffer.getTextureId(), IDENTITY_MATRIX, frame.getRotatedWidth(), frame.getRotatedHeight(), 0, 0, eglBase.surfaceWidth(), eglBase.surfaceHeight());

                    GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0);
                    GlUtil.checkNoGLES2Error("BlurEglRenderer.renderFrameOnRenderThread");
                    GLES20.glClearColor(0 /* red */, 0 /* green */, 0 /* blue */, 0 /* alpha */);
                    GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT);
                    secondPassBlurDrawer.drawRgb(secondTextureFramebuffer.getTextureId(), IDENTITY_MATRIX, frame.getRotatedWidth(), frame.getRotatedHeight(), 0, 0, eglBase.surfaceWidth(), eglBase.surfaceHeight());

                } else {
                    GLES20.glClearColor(0 /* red */, 0 /* green */, 0 /* blue */, 0 /* alpha */);
                    GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT);
                    frameDrawer.drawFrame(frame, drawer, drawMatrix, 0 /* viewportX */, 0 /* viewportY */,
                            eglBase.surfaceWidth(), eglBase.surfaceHeight());
                    // passThroughDrawer.drawRgb(snapshotTextureFramebuffer.getTextureId(), IDENTITY_MATRIX, frame.getRotatedWidth(), frame.getRotatedHeight(), 0, 0, eglBase.surfaceWidth(), eglBase.surfaceHeight());
                }
                final long swapBuffersStartTimeNs = System.nanoTime();
                if (usePresentationTimeStamp) {
                    eglBase.swapBuffers(frame.getTimestampNs());
                } else {
                    eglBase.swapBuffers();
                }

                final long currentTimeNs = System.nanoTime();
                synchronized (statisticsLock) {
                    ++framesRendered;
                    renderTimeNs += (currentTimeNs - startTimeNs);
                    renderSwapBufferTimeNs += (currentTimeNs - swapBuffersStartTimeNs);
                }
            }
            notifyCallbacks(frame, shouldRenderFrame);
        } catch (GlUtil.GlOutOfMemoryException e) {
            logE("Error while drawing frame", e);
            final ErrorCallback errorCallback = this.errorCallback;
            if (errorCallback != null) {
                errorCallback.onGlOutOfMemory();
            }
            // Attempt to free up some resources.
            drawer.release();
            frameDrawer.release();
            passThroughDrawer.release();
            bitmapTextureFramebuffer.release();
            firstTextureFramebuffer.release();
            secondTextureFramebuffer.release();
            snapshotTextureFramebuffer.release();
            // Continue here on purpose and retry again for next frame. In worst case, this is a continous
            // problem and no more frames will be drawn.
        } finally {
            frame.release();
        }
    }

    public static void checkGlError(String op) {
        int error;
        while ((error = GLES20.glGetError()) != GLES20.GL_NO_ERROR) {
            Logging.e(TAG, op + ": glGetError: 0x" + Integer.toHexString(error));
            throw new RuntimeException("glGetError encountered (see log)");
        }
    }

    private void renderSnapshot(VideoFrame frame) {
        drawMatrix.reset();
        drawMatrix.preTranslate(0.5f, 0.5f);
        drawMatrix.preScale(mirrorHorizontally ? -1f : 1f, mirrorVertically ? -1f : 1f);
        drawMatrix.preScale(1f, -1f); // We want the output to be upside down for Bitmap.
        drawMatrix.preTranslate(-0.5f, -0.5f);
        final int scaledWidth = frame.getRotatedWidth();
        final int scaledHeight = frame.getRotatedHeight();
        snapshotTextureFramebuffer.setSize(scaledWidth, scaledHeight);

        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, snapshotTextureFramebuffer.getFrameBufferId());
        GLES20.glFramebufferTexture2D(GLES20.GL_FRAMEBUFFER, GLES20.GL_COLOR_ATTACHMENT0,
                GLES20.GL_TEXTURE_2D, snapshotTextureFramebuffer.getTextureId(), 0);

        GLES20.glClearColor(0 /* red */, 0 /* green */, 0 /* blue */, 0 /* alpha */);
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT);
        frameDrawer.drawFrame(frame, drawer, drawMatrix, 0 /* viewportX */,
                0 /* viewportY */, scaledWidth, scaledHeight);
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0);
        GlUtil.checkNoGLES2Error("EglRenderer2.notifyCallbacks");
    }

    public void snapshot(final EglRenderer2.BitmapDataCallback callback) {
        synchronized (handlerLock) {
            if (renderThreadHandler == null) {
                return;
            }
            renderThreadHandler.post(() -> {
                final int scaledWidth = snapshotTextureFramebuffer.getWidth();
                final int scaledHeight = snapshotTextureFramebuffer.getHeight();
                if (scaledWidth == 0 || scaledHeight == 0) {
                    return;
                }
                firstTextureFramebuffer.setSize(scaledWidth, scaledHeight);
                secondTextureFramebuffer.setSize(scaledWidth, scaledHeight);


//                GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, secondTextureFramebuffer.getFrameBufferId());
//                GlUtil.checkNoGLES2Error("BlurEglRenderer.renderFrameOnRenderThread");
//
//                firstPassBlurDrawer.drawRgb(snapshotTextureFramebuffer.getTextureId(), IDENTITY_MATRIX,scaledWidth, scaledHeight, 0, 0, eglBase.surfaceWidth(), eglBase.surfaceHeight());
//
//                GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0);
//                GlUtil.checkNoGLES2Error("BlurEglRenderer.renderFrameOnRenderThread");
//
//                secondPassBlurDrawer.drawRgb(secondTextureFramebuffer.getTextureId(), IDENTITY_MATRIX, scaledWidth, scaledHeight, 0, 0, eglBase.surfaceWidth(), eglBase.surfaceHeight());
//
//                eglBase.swapBuffers();


                drawMatrix.reset();
                drawMatrix.preTranslate(0.5f, 0.5f);
                drawMatrix.preScale(1.0f, -1.0f); // We want the output to be upside down for Bitmap.
                drawMatrix.preTranslate(-0.5f, -0.5f);

                float[] finalGlMatrix = RendererCommon.convertMatrixFromAndroidGraphicsMatrix(drawMatrix);

                GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, firstTextureFramebuffer.getFrameBufferId());
                GlUtil.checkNoGLES2Error("BlurEglRenderer.renderFrameOnRenderThread");
                firstPassBlurDrawer.drawRgb(snapshotTextureFramebuffer.getTextureId(), finalGlMatrix, scaledWidth, scaledHeight, 0, 0, scaledWidth, scaledHeight);
                GlUtil.checkNoGLES2Error("BlurEglRenderer.renderFrameOnRenderThread");

                GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, secondTextureFramebuffer.getFrameBufferId());
                GlUtil.checkNoGLES2Error("BlurEglRenderer.renderFrameOnRenderThread");




                secondPassBlurDrawer.drawRgb(firstTextureFramebuffer.getTextureId(), IDENTITY_MATRIX, scaledWidth, scaledHeight, 0, 0, scaledWidth, scaledHeight);
                GlUtil.checkNoGLES2Error("BlurEglRenderer.renderFrameOnRenderThread");


                final ByteBuffer bitmapBuffer = ByteBuffer.allocateDirect(scaledWidth * scaledHeight * 4);
                GLES20.glFramebufferTexture2D(GLES20.GL_FRAMEBUFFER, GLES20.GL_COLOR_ATTACHMENT0,
                        GLES20.GL_TEXTURE_2D, secondTextureFramebuffer.getTextureId(), 0);
                GLES20.glViewport(0, 0, scaledWidth, scaledHeight);
                GLES20.glReadPixels(
                        0, 0, scaledWidth, scaledHeight, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, bitmapBuffer);

                GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0);
                GlUtil.checkNoGLES2Error("EglRenderer2.notifyCallbacks");
                logD("BITMAP WIDTH: " + scaledWidth
                        + " BITMAP HEIGHT: " + scaledHeight);
                callback.onBitmapData(new EglRenderer2.BitmapData(bitmapBuffer.array(), scaledWidth,  scaledHeight));
            });
        }
    }

    private void notifyCallbacks(VideoFrame frame, boolean wasRendered) {
        if (frameListeners.isEmpty()) {
            return;
        }

        final int frameWidth = frame.getRotatedWidth();
        final int frameHeight = frame.getRotatedHeight();
        final float frameAspectRatio = (float) frameWidth / (float) frameHeight;



        Iterator<FrameListenerAndParams> it = frameListeners.iterator();
        while (it.hasNext()) {
            FrameListenerAndParams listenerAndParams = it.next();
            if (!wasRendered && listenerAndParams.applyFpsReduction) {
                continue;
            }
            it.remove();
            int width, height;
            if (listenerAndParams.listener.getWidth() >= 0) {
                width = listenerAndParams.listener.getWidth();
            } else {
                width = frameWidth;
            }
            if (listenerAndParams.listener.getHeight() >= 0) {
                height = listenerAndParams.listener.getHeight();
            } else {
                height = frameHeight;
            }
            final int scaledWidth = (int) (listenerAndParams.scale * width);
            final int scaledHeight = (int) (listenerAndParams.scale * height);

            if (scaledWidth == 0 || scaledHeight == 0) {
                listenerAndParams.listener.onFrame(null);
                continue;
            }


            final float scaleX;
            final float scaleY;

            Point displaySize = RendererCommon.getDisplaySize(RendererCommon.ScalingType.SCALE_ASPECT_FILL,
                    frameAspectRatio, scaledWidth, scaledHeight);

            final float layoutAspectRatio = (float) displaySize.x / (float) displaySize.y;

            final float drawnAspectRatio = layoutAspectRatio != 0f ? layoutAspectRatio : frameAspectRatio;

            if (frameAspectRatio > drawnAspectRatio) {
                scaleX = drawnAspectRatio / frameAspectRatio;
                scaleY = 1f;
            } else {
                scaleX = 1f;
                scaleY = frameAspectRatio / drawnAspectRatio;
            }

            drawMatrix.reset();
            drawMatrix.preTranslate(0.5f, 0.5f);
            // drawMatrix.preScale(mirrorHorizontally ? -1f : 1f, mirrorVertically ? -1f : 1f);
            drawMatrix.preScale(scaleX, -scaleY); // We want the output to be upside down for Bitmap.
            drawMatrix.preTranslate(-0.5f, -0.5f);

            bitmapTextureFramebuffer.setSize(scaledWidth, scaledHeight);

            GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, bitmapTextureFramebuffer.getFrameBufferId());
            GLES20.glFramebufferTexture2D(GLES20.GL_FRAMEBUFFER, GLES20.GL_COLOR_ATTACHMENT0,
                    GLES20.GL_TEXTURE_2D, bitmapTextureFramebuffer.getTextureId(), 0);

            GLES20.glClearColor(0 /* red */, 0 /* green */, 0 /* blue */, 0 /* alpha */);
            GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT);
            RendererCommon.GlDrawer glDrawer = bitmapDrawer; // listenerAndParams.drawer == null ? bitmapDrawer  : listenerAndParams.drawer;

            GLES20.glViewport(0, 0, scaledWidth, scaledHeight);

            float[] finalGlMatrix = RendererCommon.convertMatrixFromAndroidGraphicsMatrix(drawMatrix);
            glDrawer.drawRgb(snapshotTextureFramebuffer.getTextureId(), finalGlMatrix, frame.getRotatedWidth(), frame.getRotatedHeight(), 0, 0, scaledWidth, scaledHeight);

            GLES20.glReadPixels(
                    0, 0, scaledWidth, scaledHeight, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, listenerAndParams.listener.getBuffer());

            GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0);
            GlUtil.checkNoGLES2Error("EglRenderer2.notifyCallbacks");

            listenerAndParams.listener.onFrame(listenerAndParams.listener.getBuffer());
        }
    }

    private String averageTimeAsString(long sumTimeNs, int count) {
        return (count <= 0) ? "NA" : TimeUnit.NANOSECONDS.toMicros(sumTimeNs / count) + " us";
    }

    private void logStatistics() {
        final DecimalFormat fpsFormat = new DecimalFormat("#.0");
        final long currentTimeNs = System.nanoTime();
        synchronized (statisticsLock) {
            final long elapsedTimeNs = currentTimeNs - statisticsStartTimeNs;
            if (elapsedTimeNs <= 0 || (minRenderPeriodNs == Long.MAX_VALUE && framesReceived == 0)) {
                return;
            }
            final float renderFps = framesRendered * TimeUnit.SECONDS.toNanos(1) / (float) elapsedTimeNs;
            logD("Duration: " + TimeUnit.NANOSECONDS.toMillis(elapsedTimeNs) + " ms."
                    + " Frames received: " + framesReceived + "."
                    + " Dropped: " + framesDropped + "."
                    + " Rendered: " + framesRendered + "."
                    + " Render fps: " + fpsFormat.format(renderFps) + "."
                    + " Average render time: " + averageTimeAsString(renderTimeNs, framesRendered) + "."
                    + " Average swapBuffer time: "
                    + averageTimeAsString(renderSwapBufferTimeNs, framesRendered) + ".");
            resetStatistics(currentTimeNs);
        }
    }

    private void logE(String string, Throwable e) {
        Logging.e(TAG, name + string, e);
    }

    private void logD(String string) {
        Logging.d(TAG, name + string);
    }

    private void logW(String string) {
        Logging.w(TAG, name + string);
    }
}
