package com.cloudwebrtc.webrtc;

import android.media.MediaCodec;
import android.media.MediaFormat;
import android.media.MediaMuxer;

import androidx.annotation.NonNull;

import org.webrtc.Logging;

import java.io.IOException;
import java.nio.ByteBuffer;

public class Muxer {
    final static String TAG = "Muxer";
    private boolean mMuxerStarted;
    private MediaMuxer mMuxer;

    private Object lock = new Object();
    private int numTracks;
    private int expectedTracks;

    public Muxer(String outputFile, int format, int tracks)  throws IOException {
        mMuxer = new MediaMuxer(outputFile, format);
        this.expectedTracks = tracks;
    }

    public boolean isStarted() {
        return mMuxerStarted;
    }

    public void start() {
        synchronized (lock) {
            if (mMuxerStarted) {
                return;
            }
            if (numTracks >= expectedTracks) {
                mMuxer.start();
                mMuxerStarted = true;
            }
        }
    }

    public void release() {
        synchronized (lock) {
            if (!mMuxerStarted) {
                return;
            }
            mMuxer.release();
            mMuxerStarted = false;
            Logging.d(TAG, "DID RELEASE MUXER");
        }
    }

    public int addTrack(@NonNull MediaFormat format) {
        synchronized (lock) {
            int index = mMuxer.addTrack(format);
            numTracks++;
            return index;
        }
    }

    public void writeSampleData(int trackIndex, @NonNull ByteBuffer byteBuf,
                                @NonNull MediaCodec.BufferInfo bufferInfo)  {
        synchronized (lock) {
            if (!mMuxerStarted) {
                return;
            }
            mMuxer.writeSampleData(trackIndex, byteBuf, bufferInfo);
        }
    }


}