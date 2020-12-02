package com.cloudwebrtc.webrtc.record;

import android.util.Log;
import android.util.Size;

import com.cloudwebrtc.webrtc.GetUserMediaImpl;
import com.cloudwebrtc.webrtc.utils.EglUtils;

import org.webrtc.Logging;
import org.webrtc.VideoTrack;

import java.io.File;
import java.io.IOException;
import java.util.Map;

import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.PluginRegistry;


public class RTCRecorder implements FlutterRecorder, GetUserMediaImpl.CameraSwitchCallback {
    private static final String TAG = "MediaRecorderImpl";
    private final Integer id;
    private VideoTrack videoTrack;
    private volatile RTCFileRenderer videoFileRenderer;
    private boolean isRunning = false;
    private File recordFile;
    private Size size;
    private EventChannel.EventSink eventSink;
    private boolean mirror;
    private boolean disposed = false;
    private EventChannel eventChannel;
    private GetUserMediaImpl getUserMediaImpl;
    private boolean audioOnly;
    private BinaryMessenger messenger;

    public RTCRecorder(Integer id, Size size, GetUserMediaImpl getUserMediaImpl, BinaryMessenger messenger, boolean audioOnly) {
        this.id = id;
        this.size = size;
        this.getUserMediaImpl = getUserMediaImpl;
        this.messenger = messenger;
        this.audioOnly = audioOnly;
        getUserMediaImpl.addCameraSwitchListener(this);
        registerEventChannel();
    }

    private void registerEventChannel() {
        eventChannel = new EventChannel(messenger, "FlutterWebRTC/mediaRecorderEvents/" + this.id);
        eventChannel.setStreamHandler(
                new EventChannel.StreamHandler() {
                    @Override
                    public void onListen(Object arguments, EventChannel.EventSink eventSink) {
                        RTCRecorder.this.eventSink = eventSink;
                    }

                    @Override
                    public void onCancel(Object arguments) {
                        RTCRecorder.this.eventSink = null;
                    }
                });
    }

    public void addVideoTrack(VideoTrack videoTrack, boolean isLocal, boolean isMirror, String label) {
        VideoTrack oldVideoTrack = this.videoTrack;
        this.mirror = isMirror;
        if (oldVideoTrack != videoTrack) {
            if (oldVideoTrack != null && videoFileRenderer != null) {
                oldVideoTrack.removeSink(videoFileRenderer);
                videoFileRenderer.release();
                videoFileRenderer = null;
            }
            this.videoTrack = videoTrack;
        }
    }

    public void removeVideoTrack(VideoTrack videoTrack, boolean isLocal, boolean isMirror, String label) {
        addVideoTrack(null, isLocal, isMirror, label);
    }

    public void startRecording(File file) throws IOException {
        recordFile = file;
        if (isRunning)
            return;
        isRunning = true;
        //noinspection ResultOfMethodCallIgnored
        file.getParentFile().mkdirs();
        if (videoTrack != null) {
            videoFileRenderer = new RTCFileRenderer(
                    file.getAbsolutePath(),
                    size.getWidth(),
                    size.getHeight(),
                    EglUtils.getRootEglBaseContext(),
                    true
            );
            videoFileRenderer.setMirror(mirror);
            videoTrack.addSink(videoFileRenderer);
            videoFileRenderer.startRecord();
        } else {
            Log.e(TAG, "Video track is null");
        }

    }

    public void setPaused(boolean paused) {
        if (!isRunning)
            return;
        if (videoFileRenderer != null) {
            videoFileRenderer.setPaused(paused);
        } else {
            Log.e(TAG, "Video file recorder is null");
        }
    }


    public File getRecordFile() {
        return recordFile;
    }

    public void stopRecording() {
        doStopRecording();
    }

    private void doStopRecording() {
        if (!isRunning) {
            return;
        }
        isRunning = false;
        Logging.d(TAG, "stopRecording");
        if (videoTrack != null && videoFileRenderer != null) {
            videoTrack.removeSink(videoFileRenderer);
            videoFileRenderer.stopAudRecord();
            videoFileRenderer.release();
            videoFileRenderer = null;
        }
    }

    public void pauseRecording() {
        if (videoFileRenderer != null) {
            videoFileRenderer.pauseRecording();
        }
    }

    public void resumeRecording() {
        if (videoFileRenderer != null) {
            videoFileRenderer.resumeRecording();
        }
    }

    public void dispose() {
        if (disposed) {
            return;
        }
        disposed = true;

        eventSink = null;
        if (eventChannel != null) {
            eventChannel.setStreamHandler(null);
        }
        doStopRecording();
        getUserMediaImpl.removeCameraSwitchListener(this);
    }

    public void willSwitchCamera(boolean isFacing, String trackId) {
        if (videoTrack == null || !videoTrack.id().equals(trackId)) {
            return;
        }
        // Log.d(TAG, "CameraSwitchCallback mediarecorder will switch:" + trackId + " : facing mode :" + isFacing);
        if (videoFileRenderer != null) {
            videoTrack.removeSink(videoFileRenderer);
        }
    }

    public void didSwitchCamera(boolean isFacing, String trackId) {
        if (videoTrack == null || !videoTrack.id().equals(trackId)) {
            return;
        }
        mirror = isFacing;
        if (videoFileRenderer != null) {
            videoFileRenderer.setMirror(mirror);
            videoTrack.addSink(videoFileRenderer);
        }
    }

    public void didFailSwitch(String trackId) {
        if (videoTrack == null || !videoTrack.id().equals(trackId)) {
            return;
        }
        // Log.d(TAG, "CameraSwitchCallback mediarecorder  did fail switch:" + trackId);
        if (videoFileRenderer != null) {
            videoTrack.addSink(videoFileRenderer);
        }
    }
}