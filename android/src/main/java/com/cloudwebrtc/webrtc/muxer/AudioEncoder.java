package com.cloudwebrtc.webrtc.muxer;

import android.media.AudioFormat;
import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaFormat;

import java.io.IOException;

/**
 * @hide
 */
public class AudioEncoder extends AndroidEncoder {

    private static final String TAG = "AudioEncoder";
    private static final boolean VERBOSE = false;

    protected static final String AAC_MIME_TYPE = "audio/mp4a-latm";                    // AAC Low Overhead Audio Transport Multiplex

    private static final String OPUS_MIME_TYPE = "audio/opus";

    // Configurable options
    protected int mChannelConfig;
    protected int mSampleRate;

    /**
     * Configures encoder and muxer state, and prepares the input Surface.
     */
    public AudioEncoder(int numChannels, int bitRate, int sampleRate, BaseMuxer muxer) throws IOException {
        super(TAG);
        switch (numChannels) {
            case 1:
                mChannelConfig = AudioFormat.CHANNEL_IN_MONO;
                break;
            case 2:
                mChannelConfig = AudioFormat.CHANNEL_IN_STEREO;
                break;
            default:
                throw new IllegalArgumentException("Invalid channel count. Must be 1 or 2");
        }
        String mimeType;


        switch(muxer.mFormat){
            case MPEG4:
                mimeType = AAC_MIME_TYPE;
                break;
            case WEBM:
                mimeType = OPUS_MIME_TYPE;
                break;
            default:
                throw new IllegalArgumentException("Unrecognized format!");
        }
        mSampleRate = sampleRate;
        mMuxer = muxer;
        mBufferInfo = new MediaCodec.BufferInfo();

        MediaFormat format = MediaFormat.createAudioFormat(mimeType, mSampleRate, mChannelConfig);
        format.setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC);
        format.setInteger(MediaFormat.KEY_BIT_RATE, bitRate);

        // Create a MediaCodec encoder, and configure it with our format.  Get a Surface
        // we can use for input and wrap it with a class that handles the EGL work.
        mEncoder = MediaCodec.createEncoderByType(mimeType);
        mEncoder.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE);
        mEncoder.start();

        mTrackIndex = -1;
    }

    /**
     * Depending on this method ties AudioEncoderCore
     * to a MediaCodec-based implementation.
     * <p/>
     * However, when reading AudioRecord samples directly
     * to MediaCode's input ByteBuffer we can avoid a memory copy
     * TODO: Measure performance gain and remove if negligible
     * @return
     */
    public MediaCodec getMediaCodec(){
        return mEncoder;
    }

    @Override
    protected boolean isSurfaceInputEncoder() {
        return false;
    }

}
