package org.s2arm.android;

import android.view.Surface;
import java.util.function.LongSupplier;

/**
 * Main-thread display-mode hint. This vote does not throttle rendering.
 *
 * Raising the rate (and clearing the vote) takes effect at once; lowering it waits until every request
 * for HOLD_NS has been below the live vote. Games whose own frame controller swaps between interval 1 and 2
 * every few seconds would otherwise switch the panel mode each time, and every switch back shows a few frames
 * at the lower refresh rate (a visible hitch). The same asymmetric hold is used by nx2android
 * (android/gfx_vk_present.c) and BananaNative (vka_present.c, 5 s, measured on an LTPO panel that was pulled
 * down to 30 Hz 24-46 times in three minutes without it).
 * FIXED_SOURCE tells the platform the content runs at a fixed rate, so it picks a refresh rate that is a
 * multiple of it instead of treating the vote as a loose preference.
 */
final class FrameRateVote {
    static final long HOLD_NS = 5_000_000_000L;
    /** Monotonic clock in nanoseconds; tests replace it to step time without sleeping. */
    static LongSupplier clock = System::nanoTime;

    private Surface surface;
    private float last = Float.NaN;
    private long lowerSince = -1;   // when requests first went below the live vote; -1 = not lowering

    void attach(Surface next) {
        detach();
        surface = next;
        last = Float.NaN;
        lowerSince = -1;
    }

    void target(float fps) {
        if (surface == null || !surface.isValid()) return;
        float valid = Float.isNaN(fps) || Float.isInfinite(fps) || fps <= 0 ? 0 : fps;
        if (Float.compare(last, valid) == 0) { lowerSince = -1; return; }
        boolean lower = valid > 0 && !Float.isNaN(last) && last > 0 && valid < last;
        if (lower) {
            long now = clock.getAsLong();
            if (lowerSince < 0) { lowerSince = now; return; }
            if (now - lowerSince < HOLD_NS) return;
        }
        lowerSince = -1;
        try {
            surface.setFrameRate(valid, Surface.FRAME_RATE_COMPATIBILITY_FIXED_SOURCE);
            last = valid;
        } catch (RuntimeException error) {
            System.err.println("[s2a] display frame-rate vote failed: " + error);
        }
    }

    void detach() {
        if (surface != null && !Float.isNaN(last) && last > 0) target(0);
        surface = null;
        last = Float.NaN;
        lowerSince = -1;
    }
}
