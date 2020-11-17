package com.cloudwebrtc.webrtc.video;

import android.net.Uri;
import android.util.Size;

import com.cloudwebrtc.webrtc.GetUserMediaImpl;
import com.cloudwebrtc.webrtc.audio.AudioMixerController;
import com.cloudwebrtc.webrtc.audio.MixerSinkCallback;
import com.cloudwebrtc.webrtc.audio.RecAudioRecorder;
import com.cloudwebrtc.webrtc.muxer.AndroidMuxer;
import com.cloudwebrtc.webrtc.muxer.BaseMuxer;
import com.cloudwebrtc.webrtc.record.AudioSamplesInterceptor;
import com.cloudwebrtc.webrtc.record.FlutterRecorder;
import com.cloudwebrtc.webrtc.utils.EglUtils;

import org.webrtc.EglBase;
import org.webrtc.EglBase14;
import org.webrtc.Logging;
import org.webrtc.VideoTrack;

import java.io.File;
import java.io.IOException;
import java.util.Map;

import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.PluginRegistry;

public class FlutterVideoRecorder implements FlutterRecorder, GetUserMediaImpl.CameraSwitchCallback, VideoMixer.OnFrameCallback {
    private static final String TAG = "flutterVideoRecorder";
    private final static boolean DEBUG = true;
    private VideoMixer videoMixer;
    private boolean isRunning;
    private File recordFile;
    private AndroidMuxer mMuxer;
    private Size size;
    private int recordId;
    private int fps;
    private static final int DEFAULT_FRAME_RATE = 30;

    private int videoBitrate;
    private int audioBitrate;

    private static final int DEFAULT_VIDEO_BITRATE = 800000;
    private static final int DEFAULT_AUDIO_BITRATE = 96000;

    private final int DEFAULT_SAMPLE_RATE = 48000;
    private final int DEFAULT_CHANNELS = 1;

    private AudioMixerController mixerController;

    private MixerSinkCallback recordSink;
    private MixerSinkCallback playbackSink;

    private RecAudioRecorder audioRecorder;

    private boolean disposed;

    private EventChannel.EventSink eventSink;
    private Object mixerLock = new Object();
    private EventChannel eventChannel;
    private AudioSamplesInterceptor recordSamplesInterceptor;
    private AudioSamplesInterceptor playbackSamplesInterceptor;
    private GetUserMediaImpl getUserMediaImpl;
    private boolean  audioOnly;
    private String format;
    private BinaryMessenger messenger;

    public FlutterVideoRecorder(Integer recordId, AudioSamplesInterceptor recordSamplesInterceptor, AudioSamplesInterceptor playbackSamplesInterceptor, Size size, String format, BinaryMessenger messenger, GetUserMediaImpl getUserMediaImpl, boolean audioOnly) {
        this(recordId, recordSamplesInterceptor, playbackSamplesInterceptor, size, DEFAULT_FRAME_RATE, DEFAULT_VIDEO_BITRATE, DEFAULT_AUDIO_BITRATE, format, messenger, getUserMediaImpl, audioOnly);
    }

    FlutterVideoRecorder(Integer recordId, AudioSamplesInterceptor recordSamplesInterceptor, AudioSamplesInterceptor playbackSamplesInterceptor, Size size, int fps, int videoBitrate, int audioBitrate, String format, BinaryMessenger messenger, GetUserMediaImpl getUserMediaImpl, boolean audioOnly) {
        this.recordId = recordId;
        this.size = size;
        this.fps = fps <= 0 ? DEFAULT_FRAME_RATE : fps;
        this.videoBitrate = videoBitrate <= 0 ? DEFAULT_VIDEO_BITRATE : videoBitrate;
        this.audioBitrate = audioBitrate <= 0 ? DEFAULT_AUDIO_BITRATE : audioBitrate;
        this.format = format;
        this.messenger = messenger;
        this.audioOnly = audioOnly;
        registerEventChannel();
        this.recordSamplesInterceptor = recordSamplesInterceptor;
        this.playbackSamplesInterceptor = playbackSamplesInterceptor;
        this.getUserMediaImpl = getUserMediaImpl;
        getUserMediaImpl.addCameraSwitchListener(this);
    }

    public int getFrameRate() {
        return fps;
    }

    private void registerEventChannel() {
        eventChannel = new EventChannel(messenger, "FlutterWebRTC/mediaRecorderEvents/" + this.recordId);
        eventChannel.setStreamHandler(
                        new EventChannel.StreamHandler() {
                            @Override
                            public void onListen(Object arguments, EventChannel.EventSink eventSink) {
                                FlutterVideoRecorder.this.eventSink = eventSink;
                            }

                            @Override
                            public void onCancel(Object arguments) {
                                FlutterVideoRecorder.this.eventSink = null;
                            }
                        });
    }

    private VideoMixer getVideoMixer() {
        if (videoMixer == null) {
            videoMixer = new VideoMixer("VideoMixer", fps, size,  videoBitrate);
            videoMixer.init((EglBase14.Context) EglUtils.getRootEglBaseContext(), EglBase.CONFIG_RECORDABLE);
        }
        return videoMixer;
    }

    private BaseMuxer getMuxer() {
        if (mMuxer == null) {
            mMuxer = AndroidMuxer.create(recordFile.getAbsolutePath(), format.equalsIgnoreCase("mpeg4") ? BaseMuxer.FORMAT.MPEG4 : BaseMuxer.FORMAT.WEBM, 2);
        }
        return mMuxer;
    }

    public void addVideoTrack(VideoTrack videoTrack, boolean isLocal, boolean isMirror, String label) {
        getVideoMixer().addVideoTrack(videoTrack, isLocal, isMirror, label);
        if (DEBUG) Logging.d(TAG, "SHOULD ADD VIDEO TRACK");
    }


    public void removeVideoTrack(VideoTrack videoTrack, boolean isLocal, boolean isMirror, String label) {
        getVideoMixer().removeVideoTrack(videoTrack, isLocal, isMirror, label);
    }

    private void initVideo() throws IOException  {
        getVideoMixer().start(getMuxer());
    }

    private void initAudio() throws Exception {
        synchronized (mixerLock) {
            mixerController = new AudioMixerController(DEFAULT_CHANNELS, DEFAULT_SAMPLE_RATE);
            if (recordSamplesInterceptor != null) {
                //audioRecordSink = new AudioMixableSink(1, 10.0f, mixerController);
                recordSink = new MixerSinkCallback(1, 1, 5.0f, DEFAULT_SAMPLE_RATE, mixerController, true);
                recordSamplesInterceptor.attachCallback(recordId, recordSink);
            }
            if (playbackSamplesInterceptor != null) {
                //audioTrackSink = new AudioSink(2, 1.0f, mixerController);
                playbackSink = new MixerSinkCallback(2, 1, 5.0f, DEFAULT_SAMPLE_RATE, mixerController, false);
                playbackSamplesInterceptor.attachCallback(recordId, playbackSink);
            }
            audioRecorder = new RecAudioRecorder(getMuxer(), audioBitrate, DEFAULT_SAMPLE_RATE, DEFAULT_CHANNELS);
            mixerController.setMixerOutputReceiver(audioRecorder);
            mixerController.start();
        }
        //audioRecorder.startRecording();
    }

    public void startRecording(File file) throws Exception {
        recordFile = file;
        if (isRunning)
            return;
        //noinspection ResultOfMethodCallIgnored
        file.getParentFile().mkdirs();
        initVideo();
        initAudio();
        isRunning = true;
    }

    public void setPaused(boolean paused) {
        if (!isRunning)
            return;
    }


    public File getRecordFile() {
        return recordFile;
    }

    public void stopRecording() {
        doStopRecording();
    }

    private void doStopRecording() {
        if (DEBUG) Logging.d(TAG, "STOP VIDEO RECORDING REQUESTED");
        if (!isRunning) {
            return;
        }
        synchronized (mixerLock) {
            if (recordSamplesInterceptor != null) {
                recordSamplesInterceptor.detachCallback(recordId);
            }
            if (playbackSamplesInterceptor != null) {
                playbackSamplesInterceptor.detachCallback(recordId);
            }
            recordSink = null;
            playbackSink = null;
            if (mixerController != null) {
                mixerController.release();
                mixerController = null;
            }
        }

        if (videoMixer != null) {
            videoMixer.stop();
            videoMixer = null;
        }

        if (audioRecorder != null) {
            if (DEBUG) Logging.d(TAG, "SHOULD STOP AUDIO RECORDING");
            audioRecorder.stopRecording();
            audioRecorder = null;
        }
        if (DEBUG) Logging.d(TAG, "DID STOP AUDIO RECORDING");


        if (DEBUG) Logging.d(TAG, "ABOUT TO STOP RECORDING");
        synchronized (mMuxer) {
            mMuxer.release();
        }
        isRunning = false;
        if (DEBUG) Logging.d(TAG, "DID STOP RECORDING");
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
        if (DEBUG) Logging.d(TAG, "MEDIA RECORDER DISPOSED");
        getUserMediaImpl.removeCameraSwitchListener(this);
    }


    public void didCaptureMixedFrame() {

    }

    public void onStopVideoMixing() {

    }


    public void willSwitchCamera(boolean isFacing, String trackId) {
        if (videoMixer == null) {
            return;
        }
        videoMixer.willSwitchCamera(isFacing, trackId);
    }


    public void didSwitchCamera(boolean isFacing, String trackId) {
        if (videoMixer == null) {
            return;
        }
        videoMixer.didSwitchCamera(isFacing, trackId);
    }

    public void didFailSwitch(String trackId) {
        if (videoMixer == null) {
            return;
        }
        videoMixer.didFailSwitch(trackId);
    }

}

