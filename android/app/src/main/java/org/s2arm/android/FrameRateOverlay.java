package org.s2arm.android;

import android.content.Context;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.widget.TextView;
import java.util.Locale;

/** One lightweight UI refresh per second, independent of the diagnostic panel. */
final class FrameRateOverlay extends TextView {
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final FrameRateSample sample = new FrameRateSample();
    private boolean resumed, enabled;
    private final Runnable tick = new Runnable() {
        @Override public void run() {
            if (!resumed || !enabled) return;
            double fps = sample.sample(NativeBridge.gamePresentCount(), SystemClock.elapsedRealtimeNanos());
            setText(Double.isNaN(fps) ? "FPS —" : String.format(Locale.ROOT, "FPS %.1f", fps));
            handler.postDelayed(this, 1000);
        }
    };

    FrameRateOverlay(Context context) {
        super(context);
        setTextColor(0xFFFFFFFF);
        setTextSize(14);
        setTypeface(android.graphics.Typeface.MONOSPACE);
        setBackgroundColor(0xB0000000);
        int pad = Math.round(6 * getResources().getDisplayMetrics().density);
        setPadding(pad * 2, pad, pad * 2, pad);
        setClickable(false);
        setFocusable(false);
        setContentDescription(context.getString(R.string.fps_overlay_description));
        setVisibility(GONE);
    }

    void setEnabledForGame(boolean value) {
        enabled = value;
        setVisibility(value ? VISIBLE : GONE);
        refresh();
    }

    void setResumed(boolean value) { resumed = value; refresh(); }

    private void refresh() {
        handler.removeCallbacks(tick);
        sample.reset();
        setText("FPS —");
        if (enabled && resumed) handler.post(tick);
    }
}
