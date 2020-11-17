package com.cloudwebrtc.webrtc.audio;

import android.media.AudioRecord;
import android.media.MediaCodec;
import android.os.Build;
import android.os.Trace;
import android.util.Log;

import com.cloudwebrtc.webrtc.muxer.AudioEncoder;
import com.cloudwebrtc.webrtc.muxer.BaseMuxer;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.concurrent.ArrayBlockingQueue;

/**
 * Created by peerwaya on 19/06/2017.
 */

public class RecAudioRecorder implements Runnable, AudioMixerController.MixerFrameCallback{
    final static String TAG = "RecAudioRecorder";

    private final static boolean DEBUG = true;
    private long numDroppedFrames = 0L;

    private final static int MAX_NUM_FRAMES = 100;

    private ArrayBlockingQueue<byte[]> mixQueue = new ArrayBlockingQueue(MAX_NUM_FRAMES);

    private final ArrayList<AudioRecordListener> recordListeners = new ArrayList<>();

    private static final boolean TRACE = false;
    private static final boolean VERBOSE = false;

    private final Object mReadyFence = new Object();    // Synchronize audio thread readiness
    private boolean mThreadReady;                       // Is audio thread ready
    private boolean mThreadRunning;                     // Is audio thread running
    private final Object mRecordingFence = new Object();

    private boolean mRecordingRequested;
    private boolean hasReceivdFirstFrame;
    // Variables recycled between calls to sendAudioToEncoder
    MediaCodec mMediaCodec;
    AudioEncoder mAudioEnc;
    int audioInputBufferIndex;
    int audioInputLength;
    long audioAbsolutePtsUs;
    private byte[] currentFrame;
    private int mSampleRate;

    public RecAudioRecorder(BaseMuxer muxer, int bitRate, int sampleRate, int numChannels) throws IOException {
        this.mSampleRate = sampleRate;
        mAudioEnc = new AudioEncoder(numChannels, bitRate, sampleRate, muxer);
        mMediaCodec = mAudioEnc.getMediaCodec();
        mThreadReady = false;
        mThreadRunning = false;
        mRecordingRequested = false;
        if (VERBOSE) Log.i(TAG, "Finished init. encoder : ");
        startThread();
    }


    public void stopRecording() {
        Log.i(TAG, "stopRecording");
        synchronized (mRecordingFence) {
            mRecordingRequested = false;
        }
    }

    private void doStartRecording() {
        synchronized (mRecordingFence) {
            totalSamplesNum = 0;
            startPTS = 0;
            mRecordingRequested = true;
            mRecordingFence.notify();
            hasReceivdFirstFrame = true;
            onStartNotify();
        }
    }

    public boolean isRecording() {
        return mRecordingRequested;
    }


    private void startThread() {
        synchronized (mReadyFence) {
            if (mThreadRunning) {
                Log.w(TAG, "Audio thread running when start requested");
                return;
            }
            Thread audioThread = new Thread(this, "RecAudioRecorder");
            audioThread.setPriority(Thread.MAX_PRIORITY);
            audioThread.start();
            while (!mThreadReady) {
                try {
                    mReadyFence.wait();
                } catch (InterruptedException e) {
                    // ignore
                }
            }
        }
    }


    public void onBuffer(ByteBuffer byteBuffer) {
        byteBuffer.rewind();
        byte[] data;
        if (byteBuffer.hasArray()) {
            data = Arrays.copyOfRange(byteBuffer.array(), byteBuffer.arrayOffset(),
                    byteBuffer.limit() + byteBuffer.arrayOffset());
        } else {
            data = new byte[byteBuffer.remaining()];
            byteBuffer.get(data);
        }
        //byte[] data = Arrays.copyOfRange(buffer.getBuffer(), 0, buffer.getSize());
        if (mixQueue.remainingCapacity() == 0){
            mixQueue.poll();
            numDroppedFrames++;
            if (DEBUG) Log.d(TAG, "DROPPED FRAMES "+numDroppedFrames);
        }
        mixQueue.offer(data);
        if (!hasReceivdFirstFrame) {
            if (VERBOSE) Log.i(TAG, "startRecording");
            doStartRecording();
        }
    }

    @Override
    public void run() {
        // setupAudioRecord();
        // mAudioRecord.startRecording();
        synchronized (mReadyFence) {
            mThreadReady = true;
            mReadyFence.notify();
        }

        synchronized (mRecordingFence) {
            while (!mRecordingRequested) {
                try {
                    mRecordingFence.wait();
                } catch (InterruptedException e) {
                    e.printStackTrace();
                }
            }
        }
        if (VERBOSE) Log.i(TAG, "Begin Audio transmission to encoder. encoder : ");

        while (mRecordingRequested) {
            if (TRACE) Trace.beginSection("sendAudio");
            mAudioEnc.drainEncoder(false);
            if (TRACE) Trace.endSection();
            if (TRACE) Trace.beginSection("drainAudio");
            sendAudioToEncoder(false);
            if (TRACE) Trace.endSection();
        }
        mThreadReady = false;
        if (VERBOSE) Log.i(TAG, "Exiting audio encode loop. Draining Audio Encoder");
        if (TRACE) Trace.beginSection("sendAudio");
        sendAudioToEncoder(true);
        if (TRACE) Trace.endSection();
        if (TRACE) Trace.beginSection("drainAudioFinal");
        mAudioEnc.drainEncoder(true);
        if (TRACE) Trace.endSection();
        mMediaCodec.stop();
        mMediaCodec.release();
        mThreadRunning = false;
        synchronized (mRecordingFence) {
            onEndNotify();
        }
    }


    private void sendAudioToEncoder(boolean endOfStream) {
        // send current frame data to encoder
        if (DEBUG) Log.i(TAG, "sendAudioToEncoder");
        while (!mixQueue.isEmpty()) {
            currentFrame = mixQueue.poll();
            if (currentFrame == null) {
                return;
            }
            try {
                audioInputBufferIndex = mMediaCodec.dequeueInputBuffer(0);
                if (audioInputBufferIndex >= 0) {
                    ByteBuffer inputBuffer = mMediaCodec.getInputBuffer(audioInputBufferIndex);
                    int bytesRead = currentFrame.length;
                    if (DEBUG) Log.d(TAG, "Encode AudioFrame Buffer Remaining: " + bytesRead);
                    inputBuffer.put(currentFrame);
                    if (DEBUG) Log.d(TAG, "Bytes Read : " + bytesRead);

                    audioInputLength = bytesRead;

                    audioAbsolutePtsUs = (System.nanoTime()) / 1000L;
                    // We divide audioInputLength by 2 because audio samples are
                    // 16bit.
                    audioAbsolutePtsUs = getJitterFreePTS(audioAbsolutePtsUs, audioInputLength / 2);
                    if (DEBUG) Log.d(TAG, "AUDIO LENGTH: " + audioInputLength);
                    if (DEBUG) Log.d(TAG, "AUDIO PTS: " + audioAbsolutePtsUs / 1000);

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
        }
        if (VERBOSE) Log.i(TAG, "sendAudioToEncoder done");
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

    long startPTS = 0;
    long totalSamplesNum = 0;

    /**
     * Ensures that each audio pts differs by a constant amount from the previous one.
     *
     * @param bufferPts        presentation timestamp in us
     * @param bufferSamplesNum the number of samples of the buffer's frame
     * @return
     */
    private long getJitterFreePTS(long bufferPts, long bufferSamplesNum) {
        long correctedPts = 0;
        long bufferDuration = (1000000 * bufferSamplesNum) / (mSampleRate);
        bufferPts -= bufferDuration; // accounts for the delay of acquiring the audio buffer
        if (totalSamplesNum == 0) {
            // reset
            startPTS = bufferPts;
            totalSamplesNum = 0;
        }
        correctedPts = startPTS + (1000000 * totalSamplesNum) / (mSampleRate);
        if (bufferPts - correctedPts >= 2 * bufferDuration) {
            // reset
            startPTS = bufferPts;
            totalSamplesNum = 0;
            correctedPts = startPTS;
        }
        totalSamplesNum += bufferSamplesNum;
        return correctedPts;
    }


    public void addAudioRecordListener(AudioRecordListener listener) {
        synchronized (mRecordingFence) {
            recordListeners.add(listener);
        }
    }

    public void removeAudioRecordListener(AudioRecordListener listener) {
        synchronized (mRecordingFence) {
            recordListeners.remove(listener);
        }
    }


    public static interface AudioRecordListener {
        void onAudioRecordStarted();

        void onAudioRecordEnded();
    }

    private void onStartNotify() {
        for (AudioRecordListener listener : recordListeners) {
            listener.onAudioRecordStarted();
        }
    }

    private void onEndNotify() {
        for (AudioRecordListener listener : recordListeners) {
            listener.onAudioRecordEnded();
        }
    }

}