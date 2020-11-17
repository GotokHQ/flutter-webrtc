package com.cloudwebrtc.webrtc.muxer;

import android.media.MediaCodec;
import android.media.MediaFormat;
import android.util.Log;

import java.nio.ByteBuffer;

public abstract class AndroidEncoder {
    private  String name = "VideoEncoder";
    protected BaseMuxer mMuxer;
    protected MediaCodec mEncoder;
    protected MediaCodec.BufferInfo mBufferInfo;
    protected int mTrackIndex;
    protected volatile boolean mForceEos = false;

    int mEosSpinCount = 0;
    final int MAX_EOS_SPINS = 10;
    
    protected AndroidEncoder(String name) {
        this.name = name;
    }
    
    private final static boolean VERBOSE = false;
 
    public void signalEndOfStream() {
        mForceEos = true;
    }

    public void release(){
        if(mMuxer != null)
            mMuxer.onEncoderReleased(mTrackIndex);
        if (mEncoder != null) {
            mEncoder.stop();
            mEncoder.release();
            mEncoder = null;
            if (VERBOSE) Log.i(name, "Released encoder");
        }
    }


    public void drainEncoder(boolean endOfStream) {
        final int TIMEOUT_USEC = 10000;
        Log.d(name, "drainEncoder(" + endOfStream + ")");

        if (endOfStream && isSurfaceInputEncoder()) {
            Log.d(name, "sending EOS to encoder");
            mEncoder.signalEndOfInputStream();
        }
        synchronized (mMuxer) {
            while (true) {
                int outputBufferId = mEncoder.dequeueOutputBuffer(mBufferInfo, TIMEOUT_USEC);
                if (outputBufferId >= 0) {
                    ByteBuffer encodedData = mEncoder.getOutputBuffer(outputBufferId);
                    try {
                        if ((mBufferInfo.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                            mEncoder.releaseOutputBuffer(outputBufferId, false);
                            break;
                        }
                        if (encodedData == null) {
                            Log.e(name, "encoderOutputBuffer " + outputBufferId + " was null");
                            mEncoder.releaseOutputBuffer(outputBufferId, false);
                            break;
                        }
                        if (mForceEos) {
                            mBufferInfo.flags = mBufferInfo.flags | MediaCodec.BUFFER_FLAG_END_OF_STREAM;
                            Log.i(name, "Forcing EOS");
                        }
                        mMuxer.writeSampleData(mEncoder, mTrackIndex, outputBufferId, encodedData, mBufferInfo);
                    } catch (Exception e) {
                        Log.wtf(name, e);
                        break;
                    }
                } else if (outputBufferId == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    MediaFormat newFormat = mEncoder.getOutputFormat();
                    Log.d(name, "encoder output format changed: " + newFormat);
                    // now that we have the Magic Goodies, start the muxer
                    mTrackIndex = mMuxer.addTrack(newFormat);
                } else { // encoderStatus >= 0
                    break;
                }
            }
        }
    }

    protected abstract boolean isSurfaceInputEncoder();
}