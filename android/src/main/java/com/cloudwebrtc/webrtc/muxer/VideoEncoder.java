package com.cloudwebrtc.webrtc.muxer;

import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaFormat;
import android.util.Log;
import android.view.Surface;

import java.io.IOException;


/**
 * This class wraps up the core components used for surface-input video encoding.
 * <p/>
 * Once created, frames are fed to the input surface.  Remember to provide the presentation
 * time stamp, and always call drainEncoder() before swapBuffers() to ensure that the
 * producer side doesn't get backed up.
 * <p/>
 * This class is not thread-safe, with one exception: it is valid to use the input surface
 * on one thread, and drain the output on a different thread.
 */
public class VideoEncoder extends AndroidEncoder {
    private static final String TAG = "VideoEncoder";
    private static final boolean VERBOSE = true;

    // TODO: these ought to be configurable as well
    private static final String VP8_MIME_TYPE = "video/x-vnd.on2.vp8";
    private static final String VP9_MIME_TYPE = "video/x-vnd.on2.vp9";
    private static final String H264_MIME_TYPE = "video/avc";
    private static final int IFRAME_INTERVAL = 5;

    private Surface mInputSurface;


    /**
     * Configures encoder and muxer state, and prepares the input Surface.
     */
    public VideoEncoder(int width, int height, int bitRate, int frameRate, BaseMuxer muxer) throws IOException {
        super(TAG);
        mMuxer = muxer;
        mBufferInfo = new MediaCodec.BufferInfo();

        String mimeType;


        switch(muxer.mFormat){
            case MPEG4:
                mimeType = H264_MIME_TYPE;
                break;
            case WEBM:
                mimeType = VP8_MIME_TYPE;
                break;
            default:
                throw new IllegalArgumentException("Unrecognized format!");
        }
        MediaFormat format = MediaFormat.createVideoFormat(mimeType, width, height);

        // Set some properties.  Failing to specify some of these can cause the MediaCodec
        // configure() call to throw an unhelpful exception.
        format.setInteger(MediaFormat.KEY_COLOR_FORMAT,
                MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface);
        format.setInteger(MediaFormat.KEY_BIT_RATE, bitRate);
        format.setInteger(MediaFormat.KEY_FRAME_RATE, frameRate);
        format.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, IFRAME_INTERVAL);
        if (VERBOSE) Log.d(TAG, "format: " + format);

        // Create a MediaCodec encoder, and configure it with our format.  Get a Surface
        // we can use for input and wrap it with a class that handles the EGL work.
        mEncoder = MediaCodec.createEncoderByType(mimeType);
        mEncoder.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE);
        mInputSurface = mEncoder.createInputSurface();
        mEncoder.start();

        mTrackIndex = -1;
    }

    /**
     * Returns the encoder's input surface.
     */
    public Surface getInputSurface() {
        return mInputSurface;
    }

    @Override
    protected boolean isSurfaceInputEncoder() {
        return true;
    }
}