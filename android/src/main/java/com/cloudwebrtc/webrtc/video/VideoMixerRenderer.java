package com.cloudwebrtc.webrtc.video;

import android.graphics.Matrix;
import android.graphics.Point;
import android.opengl.GLES20;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.Looper;

import org.webrtc.EglBase;
import org.webrtc.EglBase14;
import org.webrtc.GlRectDrawer;
import org.webrtc.GlTextureFrameBuffer;
import org.webrtc.GlUtil;
import org.webrtc.Logging;
import org.webrtc.RendererCommon;
import org.webrtc.ThreadUtils;
import org.webrtc.VideoFrame;
import org.webrtc.VideoFrameDrawer;
import org.webrtc.VideoSink;
import org.webrtc.VideoTrack;

import java.lang.ref.WeakReference;
import java.util.concurrent.CountDownLatch;

public class VideoMixerRenderer implements VideoSink {
    private final static boolean DEBUG = false;
    private String name = "VideoMixerRenderer";
    public final static String TAG = "VideoMixerRenderer";
    private LayoutPosition layoutPosition;
    private Long timeStamp;
    private WeakReference<VideoTrack> track;
    private final boolean local;

    private final Object layoutLock = new Object();
    private Object textureFrameLock = new Object();
    private int localFramesReceived;
    private int localFramesDropped;
    private VideoFrame pendingFrame;
    private final Matrix drawMatrix = new Matrix();
    // If true, mirrors the video stream horizontally.
    private boolean mirrorHorizontally;
    // If true, mirrors the video stream vertically.
    private boolean mirrorVertically;

    private final VideoFrameDrawer frameDrawer = new VideoFrameDrawer();
    private GlRectDrawer passThroughDrawer = new GlRectDrawer();
    private EglBase14 eglBase;
    private String label;
    private boolean renderedFirstFrame;
    private RendererCommon.GlDrawer drawer;

    GlTextureFrameBuffer textureFramebuffer =
            new GlTextureFrameBuffer(GLES20.GL_RGBA);

    private Handler renderThreadHandler;

    private final Object handlerLock = new Object();
    private final Object frameLock = new Object();
    private final EglSurfaceCreation eglSurfaceCreationRunnable = new EglSurfaceCreation();

    private static final float[] IDENTITY_MATRIX = {
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1};

    private class EglSurfaceCreation implements Runnable {

        @Override
        public synchronized void run() {
            if (eglBase != null && !eglBase.hasSurface()) {
                eglBase.createDummyPbufferSurface();
                eglBase.makeCurrent();
                // Necessary for YUV frames with odd width.
                if (DEBUG) logD("CREATED DUMMY PBUFFER SURFACE");
                GLES20.glPixelStorei(GLES20.GL_UNPACK_ALIGNMENT, 1);
            }
        }
    }

    public VideoMixerRenderer(String label, VideoTrack videoTrack, boolean local) {
        this.label = label;
        track = new WeakReference<VideoTrack>(videoTrack);
        this.local = local;
        videoTrack.addSink(this);
    }

    public void init(final EglBase14.Context sharedContext, final int[] configAttributes) {
        synchronized (handlerLock) {
            if (renderThreadHandler != null) {
                throw new IllegalStateException(name + "Already initialized");
            }
            if (DEBUG) logD("Initializing RecVideoComposer");
            final HandlerThread renderThread = new HandlerThread(name + TAG);
            renderThread.start();
            renderThreadHandler = new Handler(renderThread.getLooper());
            // Create EGL context on the newly created render thread. It should be possibly to create the
            // context on this thread and make it current on the render thread, but this causes failure on
            // some Marvel based JB devices. https://bugs.chromium.org/p/webrtc/issues/detail?id=6350.
            ThreadUtils.invokeAtFrontUninterruptibly(renderThreadHandler, new Runnable() {
                @Override
                public void run() {
                    drawer = new GlRectDrawer();
                    eglBase = EglBase.createEgl14(sharedContext, configAttributes);
                }
            });
            this.renderThreadHandler.post(this.eglSurfaceCreationRunnable);
        }
    }

    public void setMirrorHorizontally(boolean mirror) {
        synchronized (layoutLock) {
            mirrorHorizontally = mirror;
        }
    }

    public VideoTrack getTrack() {
        return track.get();
    }

    public void setLayoutPosition(LayoutPosition layoutPosition) {
        synchronized (layoutLock) {
            this.layoutPosition = layoutPosition;
        }
    }

    public void onFrame(VideoFrame frame) {
        ++localFramesReceived;
        boolean dropOldFrame;
        synchronized(handlerLock) {
            if (DEBUG) logD("GOT PENDING FRAME.");
            if (renderThreadHandler == null) {
                logD("Dropping frame - Not initialized or already released.");
                return;
            }
            synchronized(this.frameLock) {
                dropOldFrame = this.pendingFrame != null;
                if (dropOldFrame) {
                    this.pendingFrame.release();
                }
                this.pendingFrame = frame;
                this.pendingFrame.retain();
                renderThreadHandler.post(this ::renderFrameOnRenderThread);
            }
            if (DEBUG) logD("SET PENDING FRAME.");
        }
        if (dropOldFrame) {
            ++localFramesDropped;
        }
    }

    private boolean renderFrameOnRenderThread() {
        // Fetch and render |pendingFrame|.
        final VideoFrame frame;
        synchronized (frameLock) {
            if (pendingFrame == null) {
                if (DEBUG) logD("Got No Pending frame");
                return false;
            }
            frame = pendingFrame;
            pendingFrame = null;
        }

        if (eglBase == null || !eglBase.hasSurface()) {
            if (DEBUG) logD("Dropping frame - No surface");
            frame.release();
            return false;
        }

        eglBase.makeCurrent();

        if (layoutPosition == null) {
            if (DEBUG) logD("Dropping frame - No layout position");
            frame.release();
            return false;
        }

        if (DEBUG) logD("BEGIN RENDER PENDING FRAME");

        final long startTimeNs = System.nanoTime();

        final float frameAspectRatio = (float) frame.getRotatedWidth() / (float) frame.getRotatedHeight();

        final float drawnAspectRatio;
        final int displayWidth;
        final int displayHeight;

        synchronized (layoutLock) {
            Point displaySize = RendererCommon.getDisplaySize(RendererCommon.ScalingType.SCALE_ASPECT_FILL,
                frameAspectRatio, layoutPosition.width, layoutPosition.height);
            if (DEBUG) logD("VIEW PORT WIDTH: "+displaySize.x);
            if (DEBUG) logD("VIEW PORT HEIGHT: "+displaySize.y);
            final float layoutAspectRatio = (float) displaySize.x / (float) displaySize.y;
            drawnAspectRatio = layoutAspectRatio != 0f ? layoutAspectRatio : frameAspectRatio;
            if (DEBUG) logD("LAYOUT ASPECT RATION: "+layoutAspectRatio);
            displayHeight = layoutPosition.height;
            displayWidth = layoutPosition.width;
            if (DEBUG) logD("LAYOUT POSITION WIDTH: "+layoutPosition.width);
            if (DEBUG) logD("LAYOUT POSITION HEIGHT: "+layoutPosition.height);
        }

        if (DEBUG) logD("FRAME ASPECT RATION: "+frameAspectRatio);

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
            textureFramebuffer.setSize(displayWidth, displayHeight);

            GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, textureFramebuffer.getFrameBufferId());
//            GLES20.glClearColor(0 /* red */, 0 /* green */, 0 /* blue */, 0 /* alpha */);
//            GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT);
            frameDrawer.drawFrame(frame, drawer, drawMatrix, 0 /* viewportX */, 0 /* viewportY */,
                    displayWidth, displayHeight);
            GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0);
            renderedFirstFrame = true;
        } catch (GlUtil.GlOutOfMemoryException e) {
            frameDrawer.release();
            if (DEBUG) logE("Error while drawing frame", e);
        } finally {
            frame.release();
        }
        return true;
    }


     boolean renderFrame() {

        if (eglBase == null || !eglBase.hasSurface()) {
            return false;
        }

        if (textureFramebuffer.getHeight() == 0 || textureFramebuffer.getWidth() == 0) {
            if (DEBUG) logD("Dropping frame - texture width or texture height is zero");
            return false;
        }


        if (DEBUG) logD("BEGIN RENDER TEXTURE FRAME");

        try {
            if (DEBUG) logD("DRAWING FRAME BUFFER: "+textureFramebuffer.getTextureId());
            passThroughDrawer.drawRgb(textureFramebuffer.getTextureId(), IDENTITY_MATRIX, textureFramebuffer.getWidth(), textureFramebuffer.getHeight(), layoutPosition.point.x /* viewportX */,
                    layoutPosition.point.y,
                    layoutPosition.width, layoutPosition.height);
        } catch (GlUtil.GlOutOfMemoryException e) {
           //  passThroughDrawer.release();
            if (DEBUG) logE("Error while drawing frame", e);
        }
        return true;
    }

    private void logD(String string) {
        if(DEBUG) {
            Logging.d(TAG, label + " "+ string);
        }
    }

    private void logE(String string, Throwable e) {
        Logging.e(TAG, label + string, e);
    }


    /**
     * Release all resources. All already posted frames will be rendered first.
     */
    protected void release() {
        final CountDownLatch cleanupBarrier = new CountDownLatch(1);
        synchronized (handlerLock) {
            if (DEBUG) logD("Starting release.");
            if (renderThreadHandler == null) {
                if (DEBUG) logD("Already released");
                return;
            }
            renderThreadHandler.postAtFrontOfQueue(new Runnable() {
                @Override
                public void run() {
                    if (DEBUG) logD("finish encoder drain.");
                    frameDrawer.release();

                    VideoTrack videoTrack = track.get();
                    if (videoTrack != null) {
                        videoTrack.removeSink(VideoMixerRenderer.this);
                    }
                    synchronized (frameLock) {
                        if (pendingFrame != null) {
                            pendingFrame.release();
                            pendingFrame = null;
                        }
                    }
                    if (drawer != null) {
                        drawer.release();
                        drawer = null;
                    }
                    if (passThroughDrawer != null) {
                        passThroughDrawer.release();
                        passThroughDrawer = null;
                    }
                    if (eglBase != null) {
                        if (DEBUG)  logD("eglBase detach and release.");
                        eglBase.detachCurrent();
                        eglBase.release();
                        eglBase = null;
                    }
                    cleanupBarrier.countDown();
                }
            });

            final Looper renderLooper = renderThreadHandler.getLooper();
            renderThreadHandler.post(new Runnable() {
                @Override
                public void run() {
                    logD("Quitting render thread.");
                    renderLooper.quit();
                }
            });
            // Don't accept any more frames or messages to the render thread.
            renderThreadHandler = null;
        }
        ThreadUtils.awaitUninterruptibly(cleanupBarrier);
    }

    public String trackId() {
        VideoTrack videoTrack = track.get();
        if (videoTrack != null) {
            return videoTrack.id();
        }
        return null;
    }

    public static class LayoutPosition {
        public Point point;
        public int width;
        public int height;
    }
}