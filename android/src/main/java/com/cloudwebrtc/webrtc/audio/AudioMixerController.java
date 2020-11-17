package com.cloudwebrtc.webrtc.audio;

import android.os.Handler;
import android.os.HandlerThread;
import android.util.Log;
import android.util.SparseArray;

import org.webrtc.AudioMixer;
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

public class AudioMixerController {
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
    private AudioMixer mixer;
    private HandlerThread renderThread;
    private Handler renderThreadHandler;
    private int sampleRate = -1;
    private int channels = -1;
    private boolean initialized;
    private SparseArray<MixerSinkCallback> sources = new SparseArray();
    //private MixerConfig mixerConfig;
    private final Runnable frameGrabberRunnable = new Runnable() {
        @Override
        public void run() {
            doMix();
            synchronized (handlerLock) {
                if (renderThreadHandler != null) {
                    renderThreadHandler.removeCallbacks(frameGrabberRunnable);
                    scheduleFrameGrabber();
                }
            }
        }
    };
    private ArrayList<AudioMixerEvent> eventListeners = new ArrayList<>();

    public AudioMixerController(int channels, int sampleRate)  throws IOException {
        this.sampleRate = sampleRate;
        this.channels = channels;
        renderThread = new HandlerThread(TAG);
        renderThread.start();
        renderThreadHandler = new Handler(renderThread.getLooper());
        init();
    }

    private void scheduleFrameGrabber() {
        renderThreadHandler.postDelayed(
                frameGrabberRunnable, 10);
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
                    listener.onMixerInitialized(AudioMixerController.this);

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
                    listener.onMixerStarted(AudioMixerController.this);
                }
            }
        });
    }

    private void notifyEnd() {
        postToRenderThread(new Runnable() {
            @Override
            public void run() {
                for (AudioMixerEvent listener : eventListeners) {
                    listener.onMixerEnd(AudioMixerController.this);
                }
            }
        });
    }

    public static interface MixerFrameCallback {
        void onBuffer(ByteBuffer buffer);
    }

    public static interface AudioMixerEvent {
        void onMixerInitialized(AudioMixerController mixerController);

        void onMixerStarted(AudioMixerController mixerController);

        void onMixerEnd(AudioMixerController mixerController);
    }
}