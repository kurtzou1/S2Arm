package org.s2arm.android;

import android.os.Build;
import android.view.Surface;
import java.lang.reflect.Constructor;
import java.lang.reflect.Method;

/** The production voter sees controlled platform Surface and API-level boundaries. */
public final class FrameRateVoteTest {
    private static void check(boolean value, String what) { if (!value) throw new AssertionError(what); }
    public static void main(String[] args) throws Exception {
        Class<?> type;
        try { type = Class.forName("org.s2arm.android.FrameRateVote"); }
        catch (ClassNotFoundException absent) { throw new AssertionError("surface frame-rate voter is missing", absent); }
        Constructor<?> ctor = type.getDeclaredConstructor(); ctor.setAccessible(true);
        Method attach = type.getDeclaredMethod("attach", Surface.class), target = type.getDeclaredMethod("target", float.class),
            detach = type.getDeclaredMethod("detach");
        attach.setAccessible(true); target.setAccessible(true); detach.setAccessible(true);
        long[] now = {1_000_000_000L};
        java.lang.reflect.Field clock = type.getDeclaredField("clock"); clock.setAccessible(true);
        clock.set(null, (java.util.function.LongSupplier) () -> now[0]);
        final long S = 1_000_000_000L;
        Object vote = ctor.newInstance(); Surface first = new Surface();
        attach.invoke(vote, first); target.invoke(vote, 60f);
        check(first.calls == 1 && first.value == 60f && first.compatibility == 1, "first vote is immediate and FIXED_SOURCE");
        target.invoke(vote, 60f); check(first.calls == 1, "unchanged vote is not repeated");
        // lowering waits 5 s of continuous lower requests
        target.invoke(vote, 30f); check(first.calls == 1, "lowering is held at first request");
        now[0] += 4 * S; target.invoke(vote, 30f); check(first.calls == 1, "lowering still held at 4 s");
        now[0] += S; target.invoke(vote, 30f); check(first.calls == 2 && first.value == 30f, "lowering voted after 5 s");
        // raising is immediate
        target.invoke(vote, 60f); check(first.calls == 3 && first.value == 60f, "raising is immediate");
        // a bounce back to the live rate restarts the hold
        target.invoke(vote, 30f); now[0] += 3 * S; target.invoke(vote, 60f);
        now[0] += 3 * S; target.invoke(vote, 30f); check(first.calls == 3, "bounce to live rate restarts the hold");
        now[0] += 4 * S; target.invoke(vote, 30f); check(first.calls == 3, "restarted hold not yet 5 s");
        now[0] += S; target.invoke(vote, 30f); check(first.calls == 4 && first.value == 30f, "restarted hold votes at 5 s");
        // clearing is immediate even while lower
        target.invoke(vote, 0f); check(first.calls == 5 && first.value == 0f, "unknown clears vote at once");
        target.invoke(vote, 30f); check(first.calls == 6 && first.value == 30f, "vote after clear is immediate");
        detach.invoke(vote);
        check(first.calls == 7 && first.value == 0f, "detach clears live surface");
        Surface second = new Surface(); Build.VERSION.SDK_INT = 29;
        attach.invoke(vote, second); target.invoke(vote, 60f); detach.invoke(vote);
        check(second.calls == 0, "pre-30 does not call unavailable API");
        System.out.println("frame vote / hold / raise / bounce / unknown / detach / pre-30 passed");
    }
}
