package com.cloudwebrtc.webrtc.video;

import android.graphics.Matrix;
import android.graphics.Point;
import android.graphics.SurfaceTexture;
import android.opengl.GLES20;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.Looper;
import android.util.Size;
import android.view.Surface;

import com.cloudwebrtc.webrtc.GetUserMediaImpl;
import com.cloudwebrtc.webrtc.audio.AudioMixerController;
import com.cloudwebrtc.webrtc.muxer.BaseMuxer;
import com.cloudwebrtc.webrtc.muxer.VideoEncoder;
import com.cloudwebrtc.webrtc.utils.EglUtils;

import org.webrtc.EglBase;
import org.webrtc.EglBase14;
import org.webrtc.GlRectDrawer;
import org.webrtc.Logging;
import org.webrtc.RendererCommon;
import org.webrtc.ThreadUtils;
import org.webrtc.VideoTrack;

import java.util.ArrayList;
import java.util.Locale;
import java.util.Optional;
import java.util.Timer;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

public class VideoMixer implements GetUserMediaImpl.CameraSwitchCallback{

    private final static boolean DEBUG = true;
    private static final long LOG_INTERVAL_SEC = 4;
    public final static String TAG = "VideoMixer";
    // Pending frame to render. Serves as a queue with size 1. Synchronized on |renderLock|.
    private final Object renderLock = new Object();

    private String name = "VideoMixer";

    Timer timer = new Timer();
    // EGL and GL resources for drawing YUV/OES textures. After initilization, these are only accessed
    // from the render thread.
    private EglBase14 eglBase;
    private RendererCommon.GlDrawer drawer;

    private final Matrix drawMatrix = new Matrix();
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

    // |renderThreadHandler| is a handler for communicating with |renderThread|, and is synchronized
    // on |handlerLock|.

    private final Object handlerLock = new Object();

    private Handler renderThreadHandler;

    private final ArrayList<VideoMixerRenderer> renderers = new ArrayList<>();

    private final EglSurfaceCreation eglSurfaceCreationRunnable = new EglSurfaceCreation();

    private boolean started;


    private boolean hasReceivedFirstFrame;

    private final int fps;

    private OnFrameCallback frameCallback;

    private Size size;
    private int bitrate;

    private VideoEncoder encoder;
    private AudioMixerController mAudioMixerController;
    private class EglSurfaceCreation implements Runnable {
        private Object surface;

        public synchronized void setSurface(Object surface) {
            this.surface = surface;
        }

        @Override
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
                updateLayout();
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

    private final Runnable frameGrabberRunnable = new Runnable() {
        @Override
        public void run() {
            if (DEBUG) logD("Grabbing frame ...");
            renderFrames();
            synchronized (handlerLock) {
                if (renderThreadHandler != null) {
                    renderThreadHandler.removeCallbacks(frameGrabberRunnable);
                    scheduleFrameGrabber();
                }
            }
        }
    };

    public VideoMixer(String name, int framesPerSecond, Size size, int bitrate) {
        this.name = name;
        this.fps = framesPerSecond;
        this.size = size;
        this.bitrate = bitrate;
    }

    /**
     * Initialize this class, sharing resources with |sharedContext|. The custom |drawer| will be used
     * for drawing frames on the EGLSurface. This class is responsible for calling release() on
     * |drawer|. It is allowed to call init() to reinitialize the renderer after a previous
     * init()/release() cycle.
     */
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
            final long currentTimeNs = System.nanoTime();
            resetStatistics(currentTimeNs);
            this.renderThreadHandler.post(this.eglSurfaceCreationRunnable);
            renderThreadHandler.postDelayed(
                    logStatisticsRunnable, TimeUnit.SECONDS.toMillis(LOG_INTERVAL_SEC));
        }
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

    public void start(final BaseMuxer muxer) {
        postToRenderThread(new Runnable() {
            @Override
            public void run() {
                try{
                    if (started) return;
                    encoder = new VideoEncoder(size.getWidth(), size.getHeight(), bitrate, fps, muxer);
                    eglBase.createSurface(encoder.getInputSurface());
                    GLES20.glPixelStorei(GLES20.GL_UNPACK_ALIGNMENT, 1);
                    updateLayout();
                    scheduleFrameGrabber();
                    started = true;
                } catch (Exception e) {

                }
            }
        });
    }

    public void stop() {
        release();
    }

    private void scheduleFrameGrabber() {
        long frameRate = 1000/ fps;
        if (DEBUG) logD("FRAME RATE : "+frameRate);
        renderThreadHandler.postDelayed(
                frameGrabberRunnable, frameRate);
    }

    public void setOnFrameCallback(OnFrameCallback frameCallback) {
        postToRenderThread(() -> this.frameCallback = frameCallback);
    }

    public void addVideoTrack(final VideoTrack track, final boolean local, boolean isMirror, final String label) {
        postToRenderThread(new Runnable() {
            @Override
            public void run() {

                VideoMixerRenderer renderer = null;

                for (VideoMixerRenderer cRenderer: renderers) {
                    VideoTrack vtrack = cRenderer.getTrack();
                    if (vtrack != null && vtrack == track) {
                        renderer = cRenderer;
                    }
                }

                renderer = new VideoMixerRenderer(label, track, local);
                renderer.setMirrorHorizontally(isMirror);
                renderer.init((EglBase14.Context) EglUtils.getRootEglBaseContext(), EglBase.CONFIG_RECORDABLE);
                renderers.add(renderer);
                if (DEBUG) logD("ADDED VIDEO TRACK");
                updateLayout();
            }
        });
    }

    public void removeVideoTrack(VideoTrack track, boolean isLocal, boolean isMirror, String label) {
        postToRenderThread(new Runnable() {
            @Override
            public void run() {
                VideoMixerRenderer composeRenderer = null;

                for (VideoMixerRenderer cRenderer: renderers) {
                    VideoTrack vtrack  = cRenderer.getTrack();
                    if (vtrack != null && vtrack == track) {
                        composeRenderer = cRenderer;
                    }
                }
                renderers.remove(composeRenderer);
                updateLayout();

            }
        });
    }

    private void updateLayout() {

        if (eglBase == null || !eglBase.hasSurface()) {
            if (DEBUG) logD("Can't update layout - No surface");
            return;
        }

        if(renderers.size() == 1) {
            VideoMixerRenderer composeRenderer = renderers.get(0);
            VideoMixerRenderer.LayoutPosition position = new VideoMixerRenderer.LayoutPosition();
            position.height =  eglBase.surfaceHeight();
            position.width =  eglBase.surfaceWidth();
            position.point = new Point(0, 0);
            composeRenderer.setLayoutPosition(position);
            if (DEBUG) logD("size of renderer at pos[0] is  width="+position.width+", height="+position.height);
        } else {

            int width = eglBase.surfaceWidth()/renderers.size();

            int xPos = 0;
            int yPos = 0;

            for(int i = 0; i < renderers.size(); i++){
                VideoMixerRenderer composeRenderer = renderers.get(i);
                VideoMixerRenderer.LayoutPosition position = new VideoMixerRenderer.LayoutPosition();
                position.height = eglBase.surfaceHeight();
                position.width = width;
                position.point = new Point(xPos, yPos);
                if (DEBUG) logD("size of renderer at pos["+ i +"] is  width="+position.width+", height="+position.height);
                if (DEBUG) logD("X of renderer at pos["+ i +"] is "+ xPos);
                if (DEBUG) logD("Y of renderer at pos["+ i +"] is "+ yPos);
                composeRenderer.setLayoutPosition(position);
                xPos += width;
            }

        }
    }


    public void createEglSurface(Surface surface) {
        this.createEglSurfaceInternal(surface);
    }

    public void createEglSurface(SurfaceTexture surfaceTexture) {
        this.createEglSurfaceInternal(surfaceTexture);
    }

    private void createEglSurfaceInternal(Object surface) {
        eglSurfaceCreationRunnable.setSurface(surface);
        postToRenderThread(eglSurfaceCreationRunnable);
    }


    /**
     * Release all resources. All already posted frames will be rendered first.
     */
    private void release() {
        final CountDownLatch cleanupBarrier = new CountDownLatch(1);
        synchronized (handlerLock) {
            if (timer != null) {
                timer.cancel();
                timer = null;
            }
            if (DEBUG) logD("Starting release.");
            if (renderThreadHandler == null) {
                if (DEBUG) logD("Already released");
                return;
            }
            renderThreadHandler.removeCallbacks(frameGrabberRunnable);
            renderThreadHandler.removeCallbacks(logStatisticsRunnable);
            // Release EGL and GL resources on render thread.
            renderThreadHandler.postAtFrontOfQueue(new Runnable() {
                @Override
                public void run() {
                    for(VideoMixerRenderer renderer : renderers) {
                        renderer.release();
                    }
                    renderers.clear();
                    if (DEBUG) logD("finish encoder drain.");
                    if (encoder != null) {
                        if (DEBUG) logD("Start encoder drain.");
                        encoder.signalEndOfStream();
                        if (hasReceivedFirstFrame) {
                            //GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT);
                            //eglBase.swapBuffers();

                            if (DEBUG) logD("Signale encoder EOS.");
                            encoder.drainEncoder(true);
                            if (DEBUG) logD("Start encoder release.");
                        }
                        encoder.release();
                        encoder =  null;
                    }
                    if (drawer != null) {
                        drawer.release();
                        drawer = null;
                    }
                    if (eglBase != null) {
                        if (DEBUG)  logD("eglBase detach and release.");
                        eglBase.detachCurrent();
                        eglBase.release();
                        eglBase = null;
                    }
                    started = false;
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

    private void logStatistics() {
        final long currentTimeNs = System.nanoTime();
        synchronized (statisticsLock) {
            final long elapsedTimeNs = currentTimeNs - statisticsStartTimeNs;
            if (elapsedTimeNs <= 0) {
                return;
            }
            final float renderFps = framesRendered * TimeUnit.SECONDS.toNanos(1) / (float) elapsedTimeNs;
            if (DEBUG) logD("Duration: " + TimeUnit.NANOSECONDS.toMillis(elapsedTimeNs) + " ms."
                    + " Frames received: " + framesReceived + "."
                    + " Dropped: " + framesDropped + "."
                    + " Rendered: " + framesRendered + "."
                    + " Render fps: " + String.format(Locale.US, "%.1f", renderFps) + "."
                    + " Average render time: " + averageTimeAsString(renderTimeNs, framesRendered) + "."
                    + " Average swapBuffer time: "
                    + averageTimeAsString(renderSwapBufferTimeNs, framesRendered) + ".");
            resetStatistics(currentTimeNs);
        }
    }

    private String averageTimeAsString(long sumTimeNs, int count) {
        return (count <= 0) ? "NA" : TimeUnit.NANOSECONDS.toMicros(sumTimeNs / count) + " μs";
    }

    private void logD(String string) {
        if(DEBUG) {
            Logging.d(TAG, name + " "+ string);
        }
    }

    private void logE(String string, Throwable e) {
        Logging.e(TAG, name + string, e);
    }
    
    private void renderFrames() {
        if (!started) {
            return;
        }
        if (eglBase == null || !eglBase.hasSurface()) {
            if (DEBUG) logD("Can't update layout - No surface");
            return;
        }
        eglBase.makeCurrent();

        GLES20.glClearColor(0 /* red */, 0 /* green */, 0 /* blue */, 0 /* alpha */);
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT);
        for(VideoMixerRenderer renderer : renderers) {
            renderer.renderFrame();
        }
        eglBase.swapBuffers();
        encoder.drainEncoder(false);
        if (!hasReceivedFirstFrame) {
            hasReceivedFirstFrame = true;
        }
    }


    public void willSwitchCamera(boolean isFacing, String trackId) {
        postToRenderThread(() -> {
            VideoMixerRenderer renderer = getRendererForTrackId(trackId);
            if (renderer == null) {
                return;
            }
            VideoTrack track = renderer.getTrack();
            if (track != null) {
                track.removeSink(renderer);
            }
        });
    }

    public void didSwitchCamera(boolean isFacing, String trackId) {
        postToRenderThread(() -> {
            VideoMixerRenderer renderer = getRendererForTrackId(trackId);
            if (renderer == null) {
                return;
            }
            renderer.setMirrorHorizontally(isFacing);
            VideoTrack track = renderer.getTrack();
            if (track != null) {
                track.addSink(renderer);
            }
        });
    }

    public void didFailSwitch(String trackId) {
        postToRenderThread(() -> {
            VideoMixerRenderer renderer = getRendererForTrackId(trackId);
            if (renderer == null) {
                return;
            }
            VideoTrack track = renderer.getTrack();
            if (track != null) {
                track.addSink(renderer);
            }
        });
    }

    private VideoMixerRenderer getRendererForTrackId(String trackId) {
        for (VideoMixerRenderer renderer : renderers) {
            if (renderer.trackId() != null && renderer.trackId().equals(trackId)) {
                return renderer;
            }
        }
        return null;
    }

    public static interface OnFrameCallback {
        void didCaptureMixedFrame();
        void onStopVideoMixing();
    }
}
