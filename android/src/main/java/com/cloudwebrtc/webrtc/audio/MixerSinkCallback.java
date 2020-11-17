package com.cloudwebrtc.webrtc.audio;

import org.webrtc.AudioMixer;
import org.webrtc.audio.JavaAudioDeviceModule;

import java.util.concurrent.ArrayBlockingQueue;

public class MixerSinkCallback extends AudioMixer.AudioMixerSource implements JavaAudioDeviceModule.SamplesReadyCallback {
    boolean shouldMix;
    AudioMixerController mixerController;
    private static final int CAPACITY = 5;
    private ArrayBlockingQueue<JavaAudioDeviceModule.AudioSamples> sampleBuffer = new ArrayBlockingQueue(CAPACITY);
    byte[] emptyBytes;
    final int framesPerBuffer;
    private static final int BUFFERS_PER_SECOND = 100;

    public MixerSinkCallback(int ssrc, int numChannels, float volume, int sampleRate, AudioMixerController mixerController, boolean shouldMix) {
        super(ssrc, numChannels, volume, sampleRate);
        this.mixerController = mixerController;
        mixerController.addAudioMixerSource(this);
        this.shouldMix = shouldMix;
        final int bytesPerFrame = numChannels * 2;
        this.framesPerBuffer = sampleRate / BUFFERS_PER_SECOND;
        this.emptyBytes = new byte[bytesPerFrame * framesPerBuffer];
    }

    public byte[] readData() throws InterruptedException{
        if (!sampleBuffer.isEmpty()) {
            JavaAudioDeviceModule.AudioSamples sample = sampleBuffer.poll();
            if (sample != null)  {
                return sample.getData();
            }
            return emptyBytes;
        } else {
            return emptyBytes;
        }
//        JavaAudioDeviceModule.AudioSamples sample = sampleBuffer.take();
//        if (sample != null)  {
//            return sample.getData();
//        }
//        return emptyBytes;
    }

    public void onWebRtcAudioRecordSamplesReady(JavaAudioDeviceModule.AudioSamples samples) {
        if (mixerController != null) {
            if (sampleBuffer.size() == CAPACITY) {
                sampleBuffer.poll();
            }
            sampleBuffer.offer(samples);
            if (shouldMix) {
                mixerController.mix();
            }
        }
    }
}