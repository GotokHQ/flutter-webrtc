package com.cloudwebrtc.webrtc.record;

import android.graphics.Matrix;
import android.graphics.Point;
import android.media.AudioFormat;
import android.media.AudioRecord;
import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaFormat;
import android.media.MediaMuxer;
import android.media.MediaRecorder;
import android.os.Build;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.Looper;
import android.os.Message;
import android.util.Log;
import android.view.Surface;

import org.webrtc.EglBase;
import org.webrtc.GlRectDrawer;
import org.webrtc.RendererCommon;
import org.webrtc.VideoFrame;
import org.webrtc.VideoFrameDrawer;
import org.webrtc.VideoSink;

import java.io.IOException;
import java.lang.ref.WeakReference;
import java.nio.ByteBuffer;

class RTCFileRenderer implements VideoSink {
    private String audioMime = "audio/mp4a-latm";   //音频编码的Mime
    private static final String TAG = "VideoFileRenderer";
    private final HandlerThread renderThread;
    private final Handler renderThreadHandler;
    private Thread audioThread;
    private int outputFileWidth = -1;
    private int outputFileHeight = -1;
    private EglBase eglBase;
    private EglBase.Context sharedContext;
    private VideoFrameDrawer frameDrawer;

    // TODO: these ought to be configurable as well
    private static final String MIME_TYPE = "video/avc";    // H.264 Advanced Video Coding
    private static final int IFRAME_INTERVAL = 1;           // 5 seconds between I-frames

    private MediaMuxer mMuxer;
    private MediaCodec mVideoEncoder;
    private MediaCodec.BufferInfo bufferInfo;
    private boolean isRunning = true;
    private boolean isPaused = false;
    private GlRectDrawer drawer;
    private Surface surface;

    private AudioRecord mRecorder;   //录音器
    private MediaCodec mAudioEnc;   //编码器，用于音频编码
    private int audioRate = 128000;   //音频编码的密钥比特率
    private int sampleRate = 48000;   //音频采样率
    private int channelCount = 2;     //音频编码通道数
    private int channelConfig = AudioFormat.CHANNEL_IN_STEREO;   //音频录制通道,默认为立体声
    private int audioFormat = AudioFormat.ENCODING_PCM_16BIT; //音频录制格式，默认为PCM16Bit
    private AudioEncoder audioEncoder;
    private int bufferSize;
    private int mAudioTrackIndex;
    private int mVideoTrackIndex;
    private String outputFile;
    private final Matrix drawMatrix = new Matrix();

    private Object lock = new Object();

    private boolean mirror;

    RTCFileRenderer(String outputFile, int width, int height, final EglBase.Context sharedContext, boolean withAudio) throws IOException {
        this.outputFile = outputFile;
        this.outputFileWidth = width;
        this.outputFileHeight = height;
        renderThread = new HandlerThread(TAG + "RenderThread");
        renderThread.start();
        renderThreadHandler = new Handler(renderThread.getLooper());
        if (withAudio) {
            initAudioEncoder();
        } else {
            audioThread = null;
        }
        bufferInfo = new MediaCodec.BufferInfo();
        this.sharedContext = sharedContext;

        // Create a MediaMuxer.  We can't add the video track and start() the muxer here,
        // because our MediaFormat doesn't have the Magic Goodies.  These can only be
        // obtained from the mVideoEncoder after it has started processing data.
        mMuxer = new MediaMuxer(outputFile,
                MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4);

        mAudioTrackIndex = withAudio ? -1 : 0;
        mVideoTrackIndex = -1;
        mMuxerStarted = false;
        initVideoEncoder();
    }

    public String getOutputFile() {
        return outputFile;
    }

    public int getFrameRate() {
        return FlutterRecorder.DEFAULT_FRAME_RATE;
    }

    private void initVideoEncoder() {
        if (outputFileWidth == -1  || outputFileHeight == -1) {
            return;
        }
        MediaFormat format = MediaFormat.createVideoFormat(MIME_TYPE, outputFileWidth, outputFileHeight);

        // Set some properties.  Failing to specify some of these can cause the MediaCodec
        // configure() call to throw an unhelpful exception.
        format.setInteger(MediaFormat.KEY_COLOR_FORMAT,
                MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface);
        format.setInteger(MediaFormat.KEY_BIT_RATE, 1200000);
        format.setInteger(MediaFormat.KEY_FRAME_RATE, FlutterRecorder.DEFAULT_FRAME_RATE);
        format.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, IFRAME_INTERVAL);

        // Create a MediaCodec mVideoEncoder, and configure it with our format.  Get a Surface
        // we can use for input and wrap it with a class that handles the EGL work.
        try {
            mVideoEncoder = MediaCodec.createEncoderByType(MIME_TYPE);
            mVideoEncoder.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE);
            renderThreadHandler.post(() -> {
                eglBase = EglBase.create(sharedContext, EglBase.CONFIG_RECORDABLE);
                surface = mVideoEncoder.createInputSurface();
                eglBase.createSurface(surface);
                eglBase.makeCurrent();
                drawer = new GlRectDrawer();
                mVideoEncoder.start();
            });
        } catch (Exception e) {
            Log.wtf(TAG, e);
        }
    }

    private void initAudioEncoder() {
        try {
            //audio init
            MediaFormat aFormat = MediaFormat.createAudioFormat(audioMime, sampleRate, channelCount);//创建音频的格式,参数 MIME,采样率,通道数
            aFormat.setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC);//编码方式
            aFormat.setInteger(MediaFormat.KEY_BIT_RATE, audioRate);//比特率
            mAudioEnc = MediaCodec.createEncoderByType(audioMime);//创建音频编码器
            mAudioEnc.configure(aFormat, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE);//配置
            bufferSize = AudioRecord.getMinBufferSize(sampleRate, channelConfig, audioFormat);//设置bufferSize为AudioRecord所需最小bufferSize的两倍 15360
            mRecorder = new AudioRecord(MediaRecorder.AudioSource.MIC, sampleRate, channelConfig,
                    audioFormat, bufferSize);//初始化录音器
            mAudioEnc.start();
            mRecorder.startRecording();
            audioEncoder = new AudioEncoder();
            audioThread = new Thread(audioEncoder);
            audioThread.start();
            Log.d(TAG, "Started audio thread");
        } catch (Exception e) {
            Log.wtf(TAG, e);
        }
    }

    public void setPaused(boolean paused) {
        if (isPaused != paused) {
            isPaused = paused;
        }
    }

    public void setMirror(boolean mirror) {
        this.mirror = mirror;
    }

    @Override
    public void onFrame(VideoFrame frame) {
        if (!isRunning || isPaused) {
            return;
        }
        if (outputFileWidth == -1) {
            outputFileWidth = frame.getRotatedWidth();
            outputFileHeight = frame.getRotatedHeight();
            initVideoEncoder();
        }
        frame.retain();
        renderThreadHandler.post(() -> renderFrameOnRenderThread(frame));
    }

    private void renderFrameOnRenderThread(VideoFrame frame) {
        if (!isRunning || isPaused) {
            frame.release();
            return;
        }
        if (frameDrawer == null) {
            frameDrawer = new VideoFrameDrawer();
        }

        final float scaleX;
        final float scaleY;

        final float frameAspectRatio = (float) frame.getRotatedWidth() / (float) frame.getRotatedHeight();
        Point displaySize = RendererCommon.getDisplaySize(RendererCommon.ScalingType.SCALE_ASPECT_FILL,
                frameAspectRatio, outputFileWidth, outputFileHeight);

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
        if (this.mirror) {
            this.drawMatrix.preScale(-1.0F, 1.0F);
        }
        drawMatrix.preScale(scaleX, scaleY); // We want the output to be upside down for Bitmap.
        drawMatrix.preTranslate(-0.5f, -0.5f);

        frameDrawer.drawFrame(frame, drawer, this.drawMatrix, 0, 0, outputFileWidth, outputFileHeight);
        frame.release();
        drainEncoder(false);
        eglBase.swapBuffers();
    }

    /**
     * Release all resources. All already posted frames will be rendered first.
     */
    void release() {
        isRunning = false;
        if (mAudioEnc != null) {
            mAudioEnc.stop();
            mAudioEnc.release();
            mAudioEnc = null;
        }
        if (mRecorder != null) {
            mRecorder.stop();
            mRecorder.release();
            mRecorder = null;
        }
        if (mVideoEncoder != null) {
            drainEncoder(true);
            mVideoEncoder.stop();
            mVideoEncoder.release();
            mVideoEncoder = null;
        }
        if (mMuxer != null) {
            // TODO: stop() throws an exception if you haven't fed it any data.  Keep track
            //       of frames submitted, and don't call stop() if we haven't written anything.
            mMuxer.stop();
            mMuxer.release();
            mMuxer = null;
        }
        renderThreadHandler.post(() -> {
            eglBase.release();
            renderThread.quit();
        });
    }

    private boolean mMuxerStarted;
    private long videoFrameStart = 0;
    private long oncePauseTime = 0;
    private long pauseDelayTime = 0;

    public void handleVideoPause() {
        isPaused = true;
        oncePauseTime = System.nanoTime();
    }

    public void handleVideoResume() {
        oncePauseTime = System.nanoTime() - oncePauseTime;
        pauseDelayTime += oncePauseTime;
        isPaused = false;
    }

    private void drainEncoder(boolean endOfStream) {
        final int TIMEOUT_USEC = 10000;
        Log.d(TAG, "drainEncoder(" + endOfStream + ")");

        if (endOfStream) {
            Log.d(TAG, "sending EOS to encoder");
            mVideoEncoder.signalEndOfInputStream();
        }

        ByteBuffer[] encoderOutputBuffers = mVideoEncoder.getOutputBuffers();
        while (true) {
            int encoderStatus = mVideoEncoder.dequeueOutputBuffer(bufferInfo, TIMEOUT_USEC);
            if (encoderStatus == MediaCodec.INFO_TRY_AGAIN_LATER) {
                break;
            } else if (encoderStatus == MediaCodec.INFO_OUTPUT_BUFFERS_CHANGED) {
                // not expected for an mVideoEncoder
                encoderOutputBuffers = mVideoEncoder.getOutputBuffers();
                Log.e(TAG, "mVideoEncoder output buffers changed");
            } else if (encoderStatus == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                // not expected for an mVideoEncoder
                synchronized (lock) {
                    if (mMuxerStarted) {
                        throw new RuntimeException("format changed twice");
                    }
                    MediaFormat newFormat = mVideoEncoder.getOutputFormat();
                    Log.d(TAG, "encoder output format changed: " + newFormat);

                    // now that we have the Magic Goodies, start the muxer
                    mVideoTrackIndex = mMuxer.addTrack(newFormat);
                    if (mVideoTrackIndex >= 0 && mAudioTrackIndex >= 0) {
                        mMuxer.start();
                        mMuxerStarted = true;
                    }
                }
            } else if (encoderStatus < 0) {
                Log.e(TAG, "unexpected result fr om mVideoEncoder.dequeueOutputBuffer: " + encoderStatus);
            } else { // encoderStatus >= 0
                try {
                    ByteBuffer encodedData = encoderOutputBuffers[encoderStatus];
                    if (encodedData == null) {
                        Log.e(TAG, "encoderOutputBuffer " + encoderStatus + " was null");
                        break;
                    }
                    if ((bufferInfo.flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0) {
                        // The codec config data was pulled out and fed to the muxer when we got
                        // the INFO_OUTPUT_FORMAT_CHANGED status.  Ignore it.
                        Log.d(TAG, "ignoring BUFFER_FLAG_CODEC_CONFIG");
                        bufferInfo.size = 0;
                    }
                    if (bufferInfo.size != 0) {
                        // It's usually necessary to adjust the ByteBuffer values to match BufferInfo.
                        encodedData.position(bufferInfo.offset);
                        encodedData.limit(bufferInfo.offset + bufferInfo.size);
                        if (videoFrameStart == 0 && bufferInfo.presentationTimeUs != 0) {
                            videoFrameStart = bufferInfo.presentationTimeUs;
                        }
                        bufferInfo.presentationTimeUs = bufferInfo.presentationTimeUs - videoFrameStart - (pauseDelayTime / 1000);
                        if (mMuxerStarted && mMuxer != null)
                            mMuxer.writeSampleData(mVideoTrackIndex, encodedData, bufferInfo);
                        isRunning = isRunning && (bufferInfo.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) == 0;
                        mVideoEncoder.releaseOutputBuffer(encoderStatus, false);
                    }
                    if ((bufferInfo.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                        break;
                    }
                } catch (Exception e) {
                    Log.wtf(TAG, e);
                    break;
                }
            }
        }
    }


    //=============================================audio==================================================
    private static final int MSG_START_RECORDING = 0;
    private static final int MSG_STOP_RECORDING = 1;
    private static final int MSG_AUDIO_STEP = 2;
    private static final int MSG_QUIT = 3;
    private static final int MSG_PAUSE = 4;
    private static final int MSG_RESUME = 5;

    class AudioEncoder implements Runnable {
        private boolean isRecording = true;
        private boolean cancelFlag = false;
        private long baseTimeStamp = -1;
        private long pauseDelayTime;
        private long oncePauseTime;
        private boolean pausing = false;
        AudioHandler mHandler;
        private Object mReadyFence = new Object();
        private boolean isReady;

        @Override
        public void run() {
            Looper.prepare();
            mHandler = new AudioHandler(this);
            synchronized (mReadyFence) {
                isReady = true;
                mReadyFence.notify();
            }
            Looper.loop();
            synchronized (mReadyFence) {
                isReady = false;
                mHandler = null;
            }
        }

        public void startRecord() {
            synchronized (mReadyFence) {
                if (!isReady) {
                    try {
                        mReadyFence.wait();
                    } catch (InterruptedException e) {
                        e.printStackTrace();
                    }
                }
                Log.d(TAG, "Should start Audio:");
                mHandler.sendEmptyMessage(MSG_START_RECORDING);
            }

        }

        public void pause() {
            mHandler.sendEmptyMessage(MSG_PAUSE);
        }

        public void resume() {
            mHandler.sendEmptyMessage(MSG_RESUME);
        }

        public void stopRecord() {
            mHandler.sendEmptyMessage(MSG_STOP_RECORDING);
        }

        public void handleStartRecord() {
            baseTimeStamp = System.nanoTime();
            mHandler.sendEmptyMessage(MSG_AUDIO_STEP);
        }

        public void handleAudioStep() {
            try {
                if (!cancelFlag) {
                    if (!pausing) {
                        if (isRecording) {
                            audioStep();
                            mHandler.sendEmptyMessage(MSG_AUDIO_STEP);
                        } else {
                            drainEncoder();
                            mHandler.sendEmptyMessage(MSG_QUIT);
                        }
                    } else {
                        if (isRecording) {
                            mHandler.sendEmptyMessage(MSG_AUDIO_STEP);
                        } else {
                            drainEncoder();
                            mHandler.sendEmptyMessage(MSG_QUIT);
                        }
                    }
                }
            } catch (IOException e) {
                e.printStackTrace();
            }

        }

        private void drainEncoder() throws IOException {
            while (!audioStep()) {
            }
        }

        public void handleAudioPause() {
            pausing = true;
            oncePauseTime = System.nanoTime();
        }

        public void handleAudioResume() {
            oncePauseTime = System.nanoTime() - oncePauseTime;
            pauseDelayTime += oncePauseTime;
            pausing = false;
        }

        public void handleStopRecord() {
            isRecording = false;
        }

        //TODO Add End Flag
        private boolean audioStep() throws IOException {
            int index = mAudioEnc.dequeueInputBuffer(0);
            if (index >= 0) {
                final ByteBuffer buffer = getInputBuffer(mAudioEnc, index);
                buffer.clear();
                int length = mRecorder.read(buffer, bufferSize);//读入数据

                if (length > 0) {
                    if (baseTimeStamp != -1) {
                        long nano = System.nanoTime();
                        long time = (nano - baseTimeStamp - pauseDelayTime) / 1000;
                        // System.out.println("TimeStampAudio=" + time + ";nanoTime=" + nano + ";baseTimeStamp=" + baseTimeStamp + ";pauseDelay=" + pauseDelayTime);
                        mAudioEnc.queueInputBuffer(index, 0, length, time, isRecording ? 0 : MediaCodec.BUFFER_FLAG_END_OF_STREAM);
                    } else {
                        mAudioEnc.queueInputBuffer(index, 0, length, 0, isRecording ? 0 : MediaCodec.BUFFER_FLAG_END_OF_STREAM);
                    }
                }
            }
            MediaCodec.BufferInfo mInfo = new MediaCodec.BufferInfo();
            int outIndex;
            do {
                outIndex = mAudioEnc.dequeueOutputBuffer(mInfo, 0);
                if (outIndex >= 0) {
                    if ((mInfo.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                        Log.e(TAG, "audio end");
                        mAudioEnc.releaseOutputBuffer(outIndex, false);
                        return true;
                    }
                    ByteBuffer buffer = getOutputBuffer(mAudioEnc, outIndex);
                    buffer.position(mInfo.offset);
                    if (mMuxerStarted && mInfo.presentationTimeUs > 0) {
                        try {
                            mMuxer.writeSampleData(mAudioTrackIndex, buffer, mInfo);
                        } catch (Exception e) {
                            e.printStackTrace();
                        }
                    }
                    mAudioEnc.releaseOutputBuffer(outIndex, false);
                } else if (outIndex == MediaCodec.INFO_TRY_AGAIN_LATER) {

                } else if (outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    synchronized (lock) {
                        mAudioTrackIndex = mMuxer.addTrack(mAudioEnc.getOutputFormat());
                        Log.e(TAG, "add audio track-->" + mAudioTrackIndex);
                        if (mAudioTrackIndex >= 0 && mVideoTrackIndex >= 0) {
                            mMuxer.start();
                            mMuxerStarted = true;
                        }
                    }
                }
            } while (outIndex >= 0);
            return false;
        }

        private ByteBuffer getInputBuffer(MediaCodec codec, int index) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                return codec.getInputBuffer(index);
            } else {
                return codec.getInputBuffers()[index];
            }
        }

        private ByteBuffer getOutputBuffer(MediaCodec codec, int index) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                return codec.getOutputBuffer(index);
            } else {
                return codec.getOutputBuffers()[index];
            }
        }
    }

    static class AudioHandler extends Handler {

        private WeakReference<AudioEncoder> encoderWeakReference;

        public AudioHandler(AudioEncoder encoder) {
            encoderWeakReference = new WeakReference(encoder);
        }

        @Override
        public void handleMessage(Message msg) {
            int what = msg.what;
            AudioEncoder audioEncoder = encoderWeakReference.get();
            if (audioEncoder == null) {
                return;
            }
            switch (what) {
                case MSG_START_RECORDING:
                    audioEncoder.handleStartRecord();
                    break;
                case MSG_STOP_RECORDING:
                    audioEncoder.handleStopRecord();
                    break;
                case MSG_AUDIO_STEP:
                    audioEncoder.handleAudioStep();
                    break;
                case MSG_PAUSE:
                    audioEncoder.handleAudioPause();
                    break;
                case MSG_RESUME:
                    audioEncoder.handleAudioResume();
                    break;
                case MSG_QUIT:
                    Looper.myLooper().quit();
                    break;
            }
        }

    }


    public void stopAudRecord() {
        if (audioEncoder == null)  {
            return;
        }
        audioEncoder.stopRecord();
        if (audioThread != null) {
            try {
                audioThread.join();
            } catch (InterruptedException e) {
                e.printStackTrace();
            }
        }
    }

    public void startRecord() {
        audioEncoder.startRecord();
    }

    public void pauseRecording() {
        audioEncoder.pause();
    }

    public void resumeRecording() {
        audioEncoder.resume();
    }
}