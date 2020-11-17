package com.cloudwebrtc.webrtc.record;

import org.webrtc.VideoTrack;

import java.io.File;
import java.io.IOException;

import io.flutter.plugin.common.MethodChannel;


public interface FlutterRecorder {
    public static final int DEFAULT_FRAME_RATE = 30;
    public void startRecording(File file) throws Exception ;
    public void stopRecording();
    public void setPaused(boolean paused);
    public void addVideoTrack(VideoTrack videoTrack, boolean isLocal, boolean isMirror, String label);
    public void removeVideoTrack(VideoTrack videoTrack, boolean isLocal, boolean isMirror, String label);
    public void dispose();
}
