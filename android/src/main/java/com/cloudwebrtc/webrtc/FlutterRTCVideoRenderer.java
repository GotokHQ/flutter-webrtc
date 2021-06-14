package com.cloudwebrtc.webrtc;

import android.graphics.Bitmap;
import android.opengl.GLES20;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;

import com.cloudwebrtc.webrtc.utils.ConstraintsArray;
import com.cloudwebrtc.webrtc.utils.ConstraintsMap;
import com.cloudwebrtc.webrtc.utils.EglUtils;

import org.webrtc.EglBase;
import org.webrtc.EglRenderer;
import org.webrtc.GlTextureFrameBuffer;
import org.webrtc.MediaStream;
import org.webrtc.RendererCommon.RendererEvents;
import org.webrtc.VideoTrack;

import java.io.ByteArrayOutputStream;
import java.nio.ByteBuffer;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Optional;
import java.util.WeakHashMap;

import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.view.TextureRegistry;

public class FlutterRTCVideoRenderer implements EventChannel.StreamHandler, GetUserMediaImpl.CameraSwitchCallback {

    private static final String TAG = FlutterWebRTCPlugin.TAG;
    EventChannel eventChannel;
    EventChannel.EventSink eventSink;
    private int id = -1;
    private boolean mirror = false;
    private GetUserMediaImpl getUserMedia;
    private Handler handler;
    private final HashMap<Integer, BlurEglRenderer.FrameListener> frameListeners = new HashMap();

    /**
     * The {@code RendererEvents} which listens to rendering events reported by
     * {@link #surfaceTextureRenderer}.
     */
    private final RendererEvents rendererEvents
            = new RendererEvents() {
        private int _rotation = 0;
        private int _width = 0, _height = 0;

        @Override
        public void onFirstFrameRendered() {
            ConstraintsMap params = new ConstraintsMap();
            params.putString("event", "didFirstFrameRendered");
            params.putInt("id", id);
            handler.post(
                    new Runnable() {
                        @Override
                        public void run() {
                            if (eventSink != null) {
                                eventSink.success(params.toMap());
                            }
                        }
                    });
        }

        @Override
        public void onFrameResolutionChanged(
                int videoWidth, int videoHeight,
                int rotation) {
            if (eventSink != null) {
                if (_width != videoWidth || _height != videoHeight) {
                    ConstraintsMap params = new ConstraintsMap();
                    params.putString("event", "didTextureChangeVideoSize");
                    params.putInt("id", id);
                    params.putDouble("width", (double) videoWidth);
                    params.putDouble("height", (double) videoHeight);
                    _width = videoWidth;
                    _height = videoHeight;
                    handler.post(
                            new Runnable() {
                                @Override
                                public void run() {
                                    if (eventSink != null) {
                                        eventSink.success(params.toMap());
                                    }
                                }
                            });
                }

                if (_rotation != rotation) {
                    ConstraintsMap params2 = new ConstraintsMap();
                    params2.putString("event", "didTextureChangeRotation");
                    params2.putInt("id", id);
                    params2.putInt("rotation", rotation);
                    _rotation = rotation;
                    handler.post(
                            new Runnable() {
                                @Override
                                public void run() {
                                    if (eventSink != null) {
                                        eventSink.success(params2.toMap());
                                    }
                                }
                            });
                }
            }
        }
    };
    private boolean disposed = false;
    private boolean mute = false;
    private SurfaceTextureRenderer surfaceTextureRenderer;
    private TextureRegistry.SurfaceTextureEntry entry;

    /**
     * The {@code VideoTrack}, if any, rendered by this {@code FlutterRTCVideoRenderer}.
     */
    private VideoTrack videoTrack;

    public FlutterRTCVideoRenderer(GetUserMediaImpl getUserMedia, TextureRegistry.SurfaceTextureEntry entry) {
        this.entry = entry;
        this.eventSink = null;
        this.getUserMedia = getUserMedia;
        handler = new Handler(Looper.getMainLooper());
    }

    public void Dispose() {
        if (disposed) {
            return;
        }
        removeRendererFromVideoTrack();
        //destroy
        if (eventChannel != null)
            eventChannel.setStreamHandler(null);

        eventSink = null;
        disposed = true;
        entry.release();
        frameListeners.clear();
    }

    public void setEventChannel(EventChannel eventChannel) {
        this.eventChannel = eventChannel;
    }

    public void setId(int id) {
        this.id = id;
    }

    @Override
    public void onListen(Object o, EventChannel.EventSink sink) {
        eventSink = sink;
    }

    @Override
    public void onCancel(Object o) {
        eventSink = null;
    }

    /**
     * "Cleans" the {@code SurfaceViewRenderer} by setting the view part to
     * opaque black and the surface part to transparent.
     */
    private void cleanSurfaceViewRenderer() {
        if (surfaceTextureRenderer == null) {
            return;
        }
        surfaceTextureRenderer.clearImage();
    }

    /**
     * Stops rendering {@link #videoTrack} and releases the associated acquired
     * resources (if rendering is in progress).
     */
    private void removeRendererFromVideoTrack() {
        if (surfaceTextureRenderer != null) {
            if (videoTrack != null) {
                videoTrack.removeSink(surfaceTextureRenderer);
            }
            surfaceTextureRenderer.release();
        }
    }

    private void setMirror(boolean mirror) {
        this.mirror = mirror;
        if (surfaceTextureRenderer != null) {
            Log.d(TAG, "setMirror:" + mirror);
            surfaceTextureRenderer.setMirror(mirror);
        }
    }

    /**
     * Sets the {@code MediaStream} to be rendered by this {@code FlutterRTCVideoRenderer}.
     * The implementation renders the first {@link VideoTrack}, if any, of the
     * specified {@code mediaStream}.
     *
     * @param mediaStream The {@code MediaStream} to be rendered by this
     * {@code FlutterRTCVideoRenderer} or {@code null}.
     */
    public void setStream(MediaStream mediaStream) {
        VideoTrack videoTrack;

        if (mediaStream == null) {
            videoTrack = null;
        } else {
            List<VideoTrack> videoTracks = mediaStream.videoTracks;

            videoTrack = videoTracks.isEmpty() ? null : videoTracks.get(0);
        }

        setVideoTrack(videoTrack);
    }

    /**
     * Sets the {@code VideoTrack} to be rendered by this {@code FlutterRTCVideoRenderer}.
     * The implementation renders the first {@link VideoTrack}, if any, of the
     * specified {@code videoTrack}.
     *
     * @param videoTrack The {@code VideoTrack} to be rendered by this
     *                   {@code FlutterRTCVideoRenderer} or {@code null}.
     */
    public void setTrack(VideoTrack videoTrack) {
        setVideoTrack(videoTrack);
    }

    /**
     * Sets the {@code VideoTrack} to be rendered by this {@code FlutterRTCVideoRenderer}.
     *
     * @param videoTrack The {@code VideoTrack} to be rendered by this
     *                   {@code FlutterRTCVideoRenderer} or {@code null}.
     */
    private void setVideoTrack(VideoTrack videoTrack) {
        VideoTrack oldVideoTrack = this.videoTrack;

        if (oldVideoTrack != videoTrack) {
            if (oldVideoTrack != null) {
                if (videoTrack == null) {
                    // If we are not going to render any stream, clean the
                    // surface.
                    cleanSurfaceViewRenderer();
                }
                removeRendererFromVideoTrack();
                //plugin.getUserMediaImpl.removeCameraSwitchListener(this);
            }

            this.videoTrack = videoTrack;

            if (videoTrack != null) {
                GetUserMediaImpl.VideoCapturerDesc desc = getUserMedia.getVideoCapturerDesc(videoTrack.id());
                if (desc != null) {
                    getUserMedia.addCameraSwitchListener(this);
                    setMirror(desc.isFrontFacing);
                }
                tryAddRendererToVideoTrack();
                if (oldVideoTrack == null) {
                    // If there was no old track, clean the surface so we start
                    // with black.
                    cleanSurfaceViewRenderer();
                }
                Log.e(TAG, "Got new VideoTrack!");
            }
        }
    }

    /**
     * Starts rendering {@link #videoTrack} if rendering is not in progress and
     * all preconditions for the start of rendering are met.
     */
    private void tryAddRendererToVideoTrack() {
        if (videoTrack == null) {
            return;
        }
        EglBase.Context sharedContext = EglUtils.getRootEglBaseContext();

        if (sharedContext == null) {
            // If SurfaceViewRenderer#init() is invoked, it will throw a
            // RuntimeException which will very likely kill the application.
            Log.e(TAG, "Failed to render a VideoTrack!");
            return;
        }
        if (surfaceTextureRenderer == null) {
            surfaceTextureRenderer = new SurfaceTextureRenderer(entry.surfaceTexture());
            surfaceTextureRenderer.setMirror(mirror);
        }
        surfaceTextureRenderer.init(sharedContext, rendererEvents);
        for (BlurEglRenderer.FrameListener listener : frameListeners.values()) {
            surfaceTextureRenderer.addFrameListener(listener);
        }
        videoTrack.addSink(surfaceTextureRenderer);
        Log.e(TAG, "Added render a VideoTrack!");
    }


    public VideoTrack track() {
        return videoTrack;
    }

    public void mute(boolean mute, final MethodChannel.Result result) {
        if (this.mute == mute) {
            result.success(null);
            return;
        }
        this.mute = mute;
        if (surfaceTextureRenderer != null && videoTrack != null) {
            if (this.mute) {
                videoTrack.removeSink(surfaceTextureRenderer);
            } else {
                videoTrack.addSink(surfaceTextureRenderer);
            }
            surfaceTextureRenderer.setBlur(this.mute);
        }
    }

    public void blur(boolean blur, final MethodChannel.Result result) {
        if (surfaceTextureRenderer != null) {
            surfaceTextureRenderer.setBlur(blur);
            handler.post(
                    new Runnable() {
                        @Override
                        public void run() {
                            result.success(null);
                        }
                    });
        } else {
            Log.e(TAG, "FAILED TO SET BLUR");
            result.error("", "Renderer not initialized", null);
        }
    }

    public void snapshot(final MethodChannel.Result result) {
        surfaceTextureRenderer.snapshot(new EglRenderer2.BitmapDataCallback() {
            @Override
            public void onBitmapData(EglRenderer2.BitmapData bitmapData) {
                if (bitmapData == null) {
                    result.error("", "No bitmap found", null);
                    return;
                }
                HashMap map = new HashMap<>();
                map.put("bytes", bitmapData.buffer);
                map.put("width", bitmapData.width);
                map.put("height", bitmapData.height);
                map.put("format", Bitmap.Config.ARGB_8888.ordinal());
                handler.post(
                        new Runnable() {
                            @Override
                            public void run() {
                                result.success(map);
                            }
                        });
            }
        });
    }

    public void addFrameListener(BlurEglRenderer.FrameListener listener) {
        frameListeners.put(listener.getId(), listener);
        if (surfaceTextureRenderer != null) {
            surfaceTextureRenderer.addFrameListener(listener);
        }
    }

    public void removeFrameListener(BlurEglRenderer.FrameListener listener) {
        frameListeners.remove(listener.getId());
        if (surfaceTextureRenderer != null) {
            surfaceTextureRenderer.removeFrameListener(listener);
        }
    }

    public void willSwitchCamera(boolean isFacing, String trackId) {
        if (videoTrack == null || !videoTrack.id().equals(trackId)) {
            return;
        }
        // Log.d(TAG, "CameraSwitchCallback will switch:" + trackId + " : facing mode :" + isFacing);
        if (surfaceTextureRenderer != null) {
            videoTrack.removeSink(surfaceTextureRenderer);
        }
    }

    public void didSwitchCamera(boolean isFacing, String trackId) {
        if (videoTrack == null || !videoTrack.id().equals(trackId)) {
            return;
        }
        // Log.d(TAG, "CameraSwitchCallback FlutterRTCVideoRenderer did switch:" + trackId + " : facing mode :" + isFacing);
        mirror = isFacing;
        if (surfaceTextureRenderer != null) {
            surfaceTextureRenderer.setMirror(mirror);
            Log.d(TAG, "CameraSwitchCallback surface texture renderer is mirrored:" + mirror);
            videoTrack.addSink(surfaceTextureRenderer);
        }
    }

    public void didFailSwitch(String trackId) {
        if (videoTrack == null || !videoTrack.id().equals(trackId)) {
            return;
        }
        // Log.d(TAG, "CameraSwitchCallback FlutterRTCVideoRenderer did fail switch:" + trackId);
        if (surfaceTextureRenderer != null) {
            videoTrack.addSink(surfaceTextureRenderer);
        }
    }
}