package com.cloudwebrtc.webrtc.audio;

import android.media.AudioRecord;
import android.media.MediaCodec;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.Process;
import android.os.Trace;
import android.util.Log;
import android.util.SparseArray;

import androidx.annotation.Nullable;

import com.cloudwebrtc.webrtc.muxer.AudioEncoder;
import com.cloudwebrtc.webrtc.muxer.BaseMuxer;

import org.webrtc.AudioMixer;
import org.webrtc.Logging;
import org.webrtc.ThreadUtils;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.util.ArrayList;
import java.util.concurrent.CountDownLatch;

//import com.github.piasy.audio_mixer.AudioBuffer;
//import com.github.piasy.audio_mixer.AudioMixer;
//import com.github.piasy.audio_mixer.MixerConfig;
//import com.github.piasy.audio_mixer.MixerSource;

/**
 * Created by peerwaya on 16/06/2017.
 */

public class AudioMixerController3 {
    private final static String TAG = "AudioMixerController";
    private final static boolean DEBUG = true;
    // Guaranteed to be supported by all devices.
    private static final int BITS_PER_SAMPLE = 16;
    private static final long AUDIO_RECORD_THREAD_JOIN_TIMEOUT_MS = 2000;
    private static final boolean TRACE = false;
    private final Object handlerLock = new Object();
    //private AudioFrame frameForMixing;
    private boolean running = false;
    private MixerFrameCallback receiver;
    private @Nullable
    AudioRecordThread audioThread;
    private AudioMixer mixer;
    private HandlerThread renderThread;
    private Handler renderThreadHandler;
    private int sampleRate = -1;
    private int channels = -1;
    private boolean initialized;
    private MediaCodec mMediaCodec;
    private AudioEncoder mAudioEnc;
    private SparseArray<MixerSinkCallback> sources = new SparseArray();
    //private MixerConfig mixerConfig;
    private final Runnable frameGrabberRunnabele = new Runnable() {
        @Override
        public void run() {
            doMix();
            synchronized (handlerLock) {
                if (renderThreadHandler != null) {
                    renderThreadHandler.removeCallbacks(frameGrabberRunnabele);
                    scheduleFrameGrabber();
                }
            }
        }
    };
    private ArrayList<AudioMixerEvent> eventListeners = new ArrayList<>();

    public AudioMixerController3(BaseMuxer muxer, int bitRate, int channels, int sampleRate)  throws IOException {
        this.sampleRate = sampleRate;
        this.channels = channels;
        this.mAudioEnc = new AudioEncoder(channels, bitRate, sampleRate, muxer);
        this.mMediaCodec = mAudioEnc.getMediaCodec();
        renderThread = new HandlerThread(TAG);
        renderThread.start();
        renderThreadHandler = new Handler(renderThread.getLooper());
        init();
    }

    private void scheduleFrameGrabber() {
        renderThreadHandler.postDelayed(
                frameGrabberRunnabele, 10);
    }

    protected void init() {
        if (initialized) {
            synchronized (handlerLock) {
                final CountDownLatch barrier = new CountDownLatch(1);
                renderThreadHandler.post(new Runnable() {
                    @Override
                    public void run() {
                        if (mixer != null) {
                            //mixer.destroy();
                            mixer.release();
                        }
                        barrier.countDown();
                    }
                });
                ThreadUtils.awaitUninterruptibly(barrier);
            }
        }
        synchronized (handlerLock) {
            ThreadUtils.invokeAtFrontUninterruptibly(renderThreadHandler, new Runnable() {
                @Override
                public void run() {
                    mixer = AudioMixer.createAudioMixer(channels);
                    //mixer = new AudioMixer(mixerConfig);
                    //frameForMixing = new AudioFrame(null);
                }
            });
            initialized = true;

            if (DEBUG) {
                Log.d(TAG, "NOTIFYING LISTENERS");
            }
            notifyInitialized();
        }
    }


    public void addAudioMixerSource(final MixerSinkCallback audioSource) {
        postToRenderThread(new Runnable() {
            @Override
            public void run() {
                addAudioMixerSrc(audioSource);
            }
        });
    }

    public void removeAudioMixerSource(final MixerSinkCallback audioSource) {
        postToRenderThread(new Runnable() {
            @Override
            public void run() {
                removeAudioMixerSrc(audioSource);
            }
        });
    }

    public void addAudioMixerSourceSync(final MixerSinkCallback audioSource) {
        synchronized (handlerLock) {
            final CountDownLatch barrier = new CountDownLatch(1);
            renderThreadHandler.post(new Runnable() {
                @Override
                public void run() {
                    addAudioMixerSrc(audioSource);
                    barrier.countDown();
                }
            });
            ThreadUtils.awaitUninterruptibly(barrier);
        }
    }

    private void addAudioMixerSrc(final MixerSinkCallback audioSource) {
        if (mixer.addAudioSource(audioSource)) {
            sources.append(audioSource.ssrc(), audioSource);
        }
    }

    private void removeAudioMixerSrc(final MixerSinkCallback audioSource) {
        if (mixer.removeSource(audioSource.ssrc())) {
            sources.remove(audioSource.ssrc());
        }
    }

    public void removeAudioMixerSourceSync(final MixerSinkCallback audioSource) {
        synchronized (handlerLock) {
            final CountDownLatch barrier = new CountDownLatch(1);
            renderThreadHandler.post(new Runnable() {
                @Override
                public void run() {
                    removeAudioMixerSrc(audioSource);
                    barrier.countDown();
                }
            });
            ThreadUtils.awaitUninterruptibly(barrier);
        }
    }

    public void start() {
        postToRenderThread(new Runnable() {
            @Override
            public void run() {
                if (!running) {
                    running = true;
                    notifyStarted();
                    audioThread = new AudioRecordThread("AudioMixerRecordJavaThread");
                    audioThread.start();
                }
            }
        });
    }


    public boolean started() {
        return running;
    }

    public boolean isInitialized() {
        return initialized;
    }

    public void mix() {
        postToRenderThread(this::renderAudioMixer);
    }

    protected void doMix() {
        renderAudioMixer();
    }

//    protected void mix(int channels, org.webrtc.AudioMixer.AudioFrame audioFrame) {
//        if (!running) {
//            return;
//        }
//        mixer.mix(channels, audioFrame);
//    }

    public void addRecordedData(final int ssrc, byte[] data, int size) {
        postToRenderThread(new Runnable() {
            @Override
            public void run() {
                if (!running) {
                    return;
                }
                mixer.addRecordedData(ssrc, data);
            }
        });
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

    private void renderAudioMixer() {
        if (!running) {
            return;
        }
        try {
            for (int i = 0; i < sources.size(); i++) {
                int key = sources.keyAt(i);
                MixerSinkCallback obj = sources.get(key);
                byte[] data = obj.readData();
                mixer.addRecordedData(obj.ssrc(), data);
            }
            ByteBuffer buffer = mixer.mix();
            if (receiver != null && buffer != null) {
                receiver.onBuffer(buffer);
            }
        } catch (InterruptedException e) {
            // Logging.d(TAG, "stopThread");
        }
    }

    /**
     * Release all resources. All already posted frames will be rendered first.
     */
    public void release() {
        final CountDownLatch cleanupBarrier = new CountDownLatch(1);
        synchronized (handlerLock) {
            if (running) {
                running = false;
            }
            renderThreadHandler.postAtFrontOfQueue(() -> {
                initialized = false;
                //sources.clear();
                eventListeners.clear();
                this.receiver = null;
                if (audioThread != null) {
                    audioThread.stopThread();
                    if (!ThreadUtils.joinUninterruptibly(audioThread, AUDIO_RECORD_THREAD_JOIN_TIMEOUT_MS)) {
                    }
                    audioThread = null;
                }
                mixer.release();
                renderThread.quit();
                cleanupBarrier.countDown();
                renderThreadHandler = null;
            });
            ThreadUtils.awaitUninterruptibly(cleanupBarrier);
        }
    }

    public void setMixerOutputReceiver(final MixerFrameCallback receiver) {
        postToRenderThread(() -> this.receiver = receiver);
    }

    public int getSampleRate() {
        return sampleRate;
    }

    public int getChannels() {
        return channels;
    }

    public void addEventListener(final AudioMixerEvent sourceEventListener) {
        postToRenderThread(new Runnable() {
            @Override
            public void run() {
                doAddEventListener(sourceEventListener);
            }
        });
    }

    public void addEventListenerSync(final AudioMixerEvent sourceEventListener) {
        synchronized (handlerLock) {
            final CountDownLatch barrier = new CountDownLatch(1);
            renderThreadHandler.post(new Runnable() {
                @Override
                public void run() {
                    doAddEventListener(sourceEventListener);
                    barrier.countDown();
                }
            });
            ThreadUtils.awaitUninterruptibly(barrier);
        }
    }

    private void doAddEventListener(AudioMixerEvent sourceEventListener) {
        if (eventListeners.indexOf(sourceEventListener) >= 0) {
            return;
        }
        ;
        eventListeners.add(sourceEventListener);
        if (DEBUG) {
            Log.d(TAG, "ADDED EVENT LISTENER: " + sourceEventListener);
        }
    }

    public void removeEventListener(final AudioMixerEvent sourceEventListener) {
        postToRenderThread(new Runnable() {
            @Override
            public void run() {
                doRemoveEventListener(sourceEventListener);
            }
        });
    }

    private void doRemoveEventListener(AudioMixerEvent sourceEventListener) {
        eventListeners.remove(sourceEventListener);
    }

    public void removeEventListenerSync(final AudioMixerEvent sourceEventListener) {
        synchronized (handlerLock) {
            final CountDownLatch barrier = new CountDownLatch(1);
            renderThreadHandler.post(new Runnable() {
                @Override
                public void run() {
                    doRemoveEventListener(sourceEventListener);
                    barrier.countDown();
                }
            });
            ThreadUtils.awaitUninterruptibly(barrier);
        }
    }

    private void notifyInitialized() {
        postToRenderThread(new Runnable() {
            @Override
            public void run() {
                for (AudioMixerEvent listener : eventListeners) {
                    listener.onMixerInitialized(AudioMixerController3.this);

                    if (DEBUG) {
                        Log.d(TAG, "NOTIFYING LISTENER: " + listener);
                    }
                }
            }
        });
    }

    private void notifyStarted() {
        postToRenderThread(new Runnable() {
            @Override
            public void run() {
                for (AudioMixerEvent listener : eventListeners) {
                    listener.onMixerStarted(AudioMixerController3.this);
                }
            }
        });
    }

    private void notifyEnd() {
        postToRenderThread(new Runnable() {
            @Override
            public void run() {
                for (AudioMixerEvent listener : eventListeners) {
                    listener.onMixerEnd(AudioMixerController3.this);
                }
            }
        });
    }

    public static interface MixerFrameCallback {
        void onBuffer(ByteBuffer buffer);
    }

    public static interface AudioMixerEvent {
        void onMixerInitialized(AudioMixerController3 mixerController);

        void onMixerStarted(AudioMixerController3 mixerController);

        void onMixerEnd(AudioMixerController3 mixerController);
    }


    private  class AudioRecordThread extends Thread {
        private volatile boolean keepAlive = true;
        long audioAbsolutePtsUs;
        long startPTS = 0;
        long totalSamplesNum = 0;

        public AudioRecordThread(String name) {
            super(name);
        }

        @Override
        public void run() {
            Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO);

            long lastTime = System.nanoTime();
            while (keepAlive) {
                try {
                    mAudioEnc.drainEncoder(false);
                    //drain encoder here
                    for (int i = 0; i < sources.size(); i++) {
                        int key = sources.keyAt(i);
                        MixerSinkCallback obj = sources.get(key);
                        byte[] data = obj.readData();
                        mixer.addRecordedData(obj.ssrc(), data);
                    }
                    ByteBuffer buffer = mixer.mix();
                    sendAudioToEncoder(buffer, false);
                } catch (InterruptedException e) {
                    // Logging.d(TAG, "stopThread");
                }
            }
            if (DEBUG) Log.i(TAG, "Exiting audio encode loop. Draining Audio Encoder");
            if (TRACE) Trace.beginSection("sendAudio");
            sendAudioToEncoder(null, true);
            if (TRACE) Trace.endSection();
            if (TRACE) Trace.beginSection("drainAudioFinal");
            mAudioEnc.drainEncoder(true);
            if (TRACE) Trace.endSection();
            mMediaCodec.stop();
            mMediaCodec.release();
        }

        private void sendAudioToEncoder(ByteBuffer data , boolean endOfStream) {
            // send current frame data to encoder
            if (DEBUG) Log.i(TAG, "sendAudioToEncoder");
            try {
                int audioInputBufferIndex = mMediaCodec.dequeueInputBuffer(0);
                if (audioInputBufferIndex >= 0) {
                    ByteBuffer inputBuffer = mMediaCodec.getInputBuffer(audioInputBufferIndex);
                    // inputBuffer.clear();
                    int audioInputLength = 0;
                    if (!endOfStream) {
                        audioInputLength = data.remaining();
                        data.rewind();
                        inputBuffer.put(data);
                    }
                    if (DEBUG) Log.d(TAG, "Encode AudioFrame Buffer Remaining: " + audioInputLength);
                    if (DEBUG) Log.d(TAG, "Bytes Read : " + audioInputLength);

                    audioAbsolutePtsUs = (System.nanoTime()) / 1000L;
                    audioAbsolutePtsUs = getJitterFreePTS(audioAbsolutePtsUs, audioInputLength / 2);

                    if (audioInputLength == AudioRecord.ERROR_INVALID_OPERATION)
                        Log.e(TAG, "Audio read error: invalid operation");
                    if (audioInputLength == AudioRecord.ERROR_BAD_VALUE)
                        Log.e(TAG, "Audio read error: bad value");
                    if (DEBUG)
                        Log.i(TAG, "queueing " + audioInputLength + " audio bytes with pts " + audioAbsolutePtsUs);
                    if (endOfStream) {
                        if (DEBUG) Log.i(TAG, "EOS received in sendAudioToEncoder");
                        mMediaCodec.queueInputBuffer(audioInputBufferIndex, 0, audioInputLength, audioAbsolutePtsUs, MediaCodec.BUFFER_FLAG_END_OF_STREAM);
                    } else {
                        mMediaCodec.queueInputBuffer(audioInputBufferIndex, 0, audioInputLength, audioAbsolutePtsUs, 0);
                    }
                } else {
                    if (DEBUG) Log.i(TAG, "audioInputBufferIndex:" + audioInputBufferIndex);
                }
            } catch (Throwable t) {
                Log.e(TAG, "_offerAudioEncoder exception");
                t.printStackTrace();
                throw new RuntimeException("somethingg went bad");
            } finally {
                //freeFrames.offer(currentFrame);
            }
            if (DEBUG) Log.i(TAG, "sendAudioToEncoder done");
        }

        // Stops the inner thread loop and also calls AudioRecord.stop().
        // Does not block the calling thread.
        public void stopThread() {
            Logging.d(TAG, "stopThread");
            keepAlive = false;
        }

        private void readError(int bytesRead) {
            String errorMessage = "AudioRecord.read failed: " + bytesRead;
            Logging.e(TAG, errorMessage);
            if (bytesRead == AudioRecord.ERROR_INVALID_OPERATION) {
                keepAlive = false;

            }
        }

        private long getJitterFreePTS(long bufferPts, long bufferSamplesNum) {
            long correctedPts = 0;
            long bufferDuration = (1000000 * bufferSamplesNum) / (sampleRate);
            bufferPts -= bufferDuration; // accounts for the delay of acquiring the audio buffer
            if (totalSamplesNum == 0) {
                // reset
                startPTS = bufferPts;
                totalSamplesNum = 0;
            }
            correctedPts = startPTS + (1000000 * totalSamplesNum) / (sampleRate);
            if (bufferPts - correctedPts >= 2 * bufferDuration) {
                // reset
                startPTS = bufferPts;
                totalSamplesNum = 0;
                correctedPts = startPTS;
            }
            totalSamplesNum += bufferSamplesNum;
            return correctedPts;
        }
    }
}