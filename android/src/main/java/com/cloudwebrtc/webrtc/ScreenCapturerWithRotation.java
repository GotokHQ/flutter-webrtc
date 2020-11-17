package com.cloudwebrtc.webrtc;

import android.content.Context;
import android.content.Intent;
import android.media.projection.MediaProjection;
import android.view.Surface;
import android.view.WindowManager;

import org.webrtc.ScreenCapturerAndroid;
import org.webrtc.VideoFrame;

public class ScreenCapturerWithRotation extends ScreenCapturerAndroid {
    private Context mContext;

    public ScreenCapturerWithRotation(Context context, Intent mediaProjectionPermissionResultData,
                                      MediaProjection.Callback mediaProjectionCallback) {
        super(mediaProjectionPermissionResultData, mediaProjectionCallback);
        mContext = context;
    }

    @Override
    public void onFrame(VideoFrame frame) {
        final VideoFrame modifiedFrame = new VideoFrame(
                frame.getBuffer(), getFrameOrientation(), frame.getTimestampNs());
        super.onFrame(modifiedFrame);
        //modifiedFrame.release();
    }

    private int getFrameOrientation() {
        return getDeviceOrientation(mContext);
    }

    static int getDeviceOrientation(Context context) {
        final WindowManager wm = (WindowManager) context.getSystemService(Context.WINDOW_SERVICE);
        switch (wm.getDefaultDisplay().getRotation()) {
            case Surface.ROTATION_90:
                return 90;
            case Surface.ROTATION_180:
                return 180;
            case Surface.ROTATION_270:
                return 270;
            case Surface.ROTATION_0:
            default:
                return 0;
        }
    }
}
