package com.cloudwebrtc.webrtc.video;

import android.graphics.Matrix;
import android.graphics.Point;
import android.opengl.GLES20;
import android.os.Handler;

import org.webrtc.EglBase14;
import org.webrtc.GlTextureFrameBuffer;
import org.webrtc.GlUtil;
import org.webrtc.Logging;
import org.webrtc.RendererCommon;
import org.webrtc.VideoFrame;
import org.webrtc.VideoFrameDrawer;
import org.webrtc.VideoSink;
import org.webrtc.VideoTrack;

import java.lang.ref.WeakReference;

public class VideoMixerRenderer2 implements VideoSink {
    private final static boolean DEBUG = false;
    public final static String TAG = "VideoMixerRenderer";
    private LayoutPosition layoutPosition;
    private Long timeStamp;
    private WeakReference<VideoTrack> track;
    private final boolean local;
    private Object frameLock = new Object();

    private int localFramesReceived;
    private int localFramesDropped;
    private VideoFrame pendingFrame;
    private final Matrix drawMatrix = new Matrix();
    // If true, mirrors the video stream horizontally.
    private boolean mirrorHorizontally;
    // If true, mirrors the video stream vertically.
    private boolean mirrorVertically;

    private boolean shouldRenderFrame = true;
    private final VideoFrameDrawer frameDrawer = new VideoFrameDrawer();
    private Handler handler;

    private Object statisticsLock;
    private Object handlerLock;
    private EglBase14 eglBase;
    private String label;
    private boolean renderedFirstFrame;
    private RendererCommon.GlDrawer drawer;

    private GlTextureFrameBuffer textureFramebuffer =
            new GlTextureFrameBuffer(GLES20.GL_RGBA);

    public VideoMixerRenderer2(String label, EglBase14 eglBase, VideoTrack videoTrack, boolean local, RendererCommon.GlDrawer drawer, Handler handler, Object handlerLock, Object statisticsLock) {
        this.label = label;
        this.eglBase = eglBase;
        track = new WeakReference<VideoTrack>(videoTrack);
        this.local = local;
        this.handlerLock = handlerLock;
        this.statisticsLock = statisticsLock;
        this.handler = handler;
        this.drawer = drawer;
        videoTrack.addSink(this);
    }


    public void setMirrorHorizontally(boolean mirror) {
        mirrorHorizontally = mirror;
    }

    public VideoTrack getTrack() {
        return track.get();
    }

    public void setLayoutPosition(LayoutPosition layoutPosition) {
        this.layoutPosition = layoutPosition;
    }

    public void onFrame(VideoFrame frame) {
        ++localFramesReceived;
        boolean dropOldFrame;
        synchronized(handlerLock) {
            if (DEBUG) logD("GOT PENDING FRAME.");
            if (handler == null) {
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
                // handler.post(this ::renderFrameOnRenderThread);
            }
            if (DEBUG) logD("SET PENDING FRAME.");
        }

        if (dropOldFrame) {
            ++localFramesDropped;
        }

    }

    boolean renderFrameOnRenderThread() {
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

        if (layoutPosition == null) {
            if (DEBUG) logD("Dropping frame - No layout position");
            frame.release();
            return false;
        }

        if (DEBUG) logD("BEGIN RENDER PENDING FRAME");

        final long startTimeNs = System.nanoTime();

        final float frameAspectRatio = (float) frame.getRotatedWidth() / (float) frame.getRotatedHeight();

        Point displaySize = RendererCommon.getDisplaySize(RendererCommon.ScalingType.SCALE_ASPECT_FILL,
                frameAspectRatio, layoutPosition.width, layoutPosition.height);

        final float layoutAspectRatio = (float) displaySize.x / (float) displaySize.y;

        final float drawnAspectRatio = layoutAspectRatio != 0f ? layoutAspectRatio : frameAspectRatio;

        if (DEBUG) logD("VIEW PORT WIDTH: "+displaySize.x);
        if (DEBUG) logD("VIEW PORT HEIGHT: "+displaySize.y);

        if (DEBUG) logD("LAYOUT POSITION WIDTH: "+layoutPosition.width);
        if (DEBUG) logD("LAYOUT POSITION HEIGHT: "+layoutPosition.height);


        if (DEBUG) logD("FRAME ASPECT RATION: "+frameAspectRatio);
        if (DEBUG) logD("LAYOUT ASPECT RATION: "+layoutAspectRatio);

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
//                GLES20.glEnable(GLES20.GL_SCISSOR_TEST);
//                GLES20.glScissor(layoutPosition.point.x /* viewportX */,
//                        layoutPosition.point.y,
//                        layoutPosition.width, layoutPosition.height);
                //GLES20.glClearColor(0 /* red */, 0 /* green */, 0 /* blue */, 0 /* alpha */);
                frameDrawer.drawFrame(frame, drawer, drawMatrix, layoutPosition.point.x /* viewportX */,
                        layoutPosition.point.y,
                        layoutPosition.width, layoutPosition.height);
                //eglBase.swapBuffers(frame.getTimestampNs());
                renderedFirstFrame = true;
            }
        } catch (GlUtil.GlOutOfMemoryException e) {
            frameDrawer.release();
            if (DEBUG) logE("Error while drawing frame", e);
        } finally {
            frame.release();
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

    public void release() {
        frameDrawer.release();
        VideoTrack videoTrack = track.get();
        if (videoTrack != null) {
            videoTrack.removeSink(this);
        }
        synchronized (frameLock) {
            if (pendingFrame != null) {
                pendingFrame.release();
                pendingFrame = null;
            }
        }
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