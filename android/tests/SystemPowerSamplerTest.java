package org.s2arm.android;

import android.content.Context;
import android.os.BatteryManager;
import android.os.Handler;
import android.os.SystemClock;
import java.lang.reflect.Constructor;
import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.function.DoubleConsumer;

/** Exercise actual sampler with Android service and looper boundaries replaced. */
public final class SystemPowerSamplerTest {
    private static int failures;
    private static void check(boolean value, String what) { if (!value) { System.err.println("FAIL " + what); failures++; } }
    private static Context discharging() {
        Context context = new Context();
        context.battery.putExtra(BatteryManager.EXTRA_STATUS, BatteryManager.BATTERY_STATUS_DISCHARGING)
            .putExtra(BatteryManager.EXTRA_PLUGGED, 0)
            .putExtra(BatteryManager.EXTRA_VOLTAGE, 4000);
        context.manager.current = -1000000;
        return context;
    }
    public static void main(String[] args) throws Exception {
        Class<?> type;
        try { type = Class.forName("org.s2arm.android.SystemPowerSampler"); }
        catch (ClassNotFoundException absent) { throw new AssertionError("BatteryManager sampler is missing", absent); }
        Constructor<?> ctor = type.getDeclaredConstructor(Context.class, Handler.class, DoubleConsumer.class);
        ctor.setAccessible(true);
        Method start = type.getDeclaredMethod("start"), stop = type.getDeclaredMethod("stop");
        start.setAccessible(true); stop.setAccessible(true);
        Context context = discharging();
        Handler handler = new Handler(); ArrayList<Double> output = new ArrayList<>();
        Object sampler = ctor.newInstance(context, handler, (DoubleConsumer) output::add);

        // 拔电后电量计要稳 8 秒：观察到的第一次读数按刚拔电处理
        SystemClock.now = 1000;
        start.invoke(sampler); handler.runPending();
        check(output.size() == 1 && Double.isNaN(output.get(0)),
            "settle window: first unplugged read unavailable");
        SystemClock.now = 8999;
        handler.runPending();
        check(output.size() == 2 && Double.isNaN(output.get(1)), "still settling at 8 s minus 1");
        SystemClock.now = 9000;
        handler.runPending();
        check(output.size() == 3 && Math.abs(output.get(2) - 4.0) < 0.000001, "settled read converts");

        // 8E 机型：放电电流报正号，幅值算功耗
        context.manager.current = 1500000;
        handler.runPending();
        check(output.size() == 4 && Math.abs(output.get(3) - 6.0) < 0.000001,
            "positive current while discharging");

        // 插电中断：不可用；再拔电重新起算 8 秒
        context.battery.putExtra(BatteryManager.EXTRA_PLUGGED, 1);
        SystemClock.now = 9500;
        handler.runPending();
        check(output.size() == 5 && Double.isNaN(output.get(4)), "plugged invalidates power");
        context.battery.putExtra(BatteryManager.EXTRA_PLUGGED, 0);
        SystemClock.now = 10000;
        handler.runPending();
        check(output.size() == 6 && Double.isNaN(output.get(5)), "re-unplug restarts settle clock");
        SystemClock.now = 18000;
        handler.runPending();
        check(output.size() == 7 && Math.abs(output.get(6) - 6.0) < 0.000001, "second settle completes");

        // 停表不采；迟到的回调被忽略
        Runnable stale = handler.pending; int reads = context.reads;
        stop.invoke(sampler);
        check(handler.pending == null, "pause removes callback");
        stale.run();
        check(context.reads == reads && output.size() == 7, "late callback does not sample");

        // 恢复采样重起 settle（停表期间状态未知）
        start.invoke(sampler); handler.runPending();
        check(output.size() == 8 && Double.isNaN(output.get(7)), "resume restarts settle");
        SystemClock.now = 26000;
        handler.runPending();
        check(output.size() == 9 && Math.abs(output.get(8) - 6.0) < 0.000001, "resumed settled read");

        // 属性不可用：电表不支持 current_now
        context.manager.current = Long.MIN_VALUE;
        handler.runPending();
        check(output.size() == 10 && Double.isNaN(output.get(9)), "unsupported property stays unavailable");

        // debug.s2a.power_readout=0：不碰 BatteryManager / registerReceiver，读数固定不可用
        android.os.SystemProperties.values.put("debug.s2a.power_readout", "0");
        context.manager.current = -1000000;
        int reads0 = context.reads;
        handler.runPending();
        check(output.size() == 11 && Double.isNaN(output.get(10)) && context.reads == reads0,
            "power_readout=0 publishes unavailable without reading battery");
        android.os.SystemProperties.values.clear();
        handler.runPending();
        check(output.size() == 12 && Math.abs(output.get(11) - 4.0) < 0.000001, "switch back on resumes real reads");
        stop.invoke(sampler);

        // 读电池不在走拍子的线程上做（ANR：系统电池服务几秒不回时界面线程被卡住）。
        // worker / main 两个执行器这里都只把任务记下、由用例决定什么时候跑——模拟「读卡住了」。
        {
            Constructor<?> ctor2 = type.getDeclaredConstructor(Context.class, Handler.class,
                java.util.concurrent.Executor.class, java.util.concurrent.Executor.class, Class.forName("org.s2arm.android.SystemPowerSampler$Sink"));
            ctor2.setAccessible(true);
            ArrayList<Runnable> work = new ArrayList<>(), back = new ArrayList<>(); ArrayList<Double> out2 = new ArrayList<>();
            Class<?> sinkType = Class.forName("org.s2arm.android.SystemPowerSampler$Sink");
            Object sink2 = java.lang.reflect.Proxy.newProxyInstance(sinkType.getClassLoader(), new Class<?>[] { sinkType },
                (proxy, method, a) -> { if (method.getName().equals("battery")) out2.add((Double) a[0]); return null; });
            Context c2 = discharging(); Handler h2 = new Handler();
            Object s2 = ctor2.newInstance(c2, h2, (java.util.concurrent.Executor) work::add, (java.util.concurrent.Executor) back::add, sink2);
            SystemClock.now = 100000;
            int r0 = c2.reads;
            start.invoke(s2); h2.runPending();
            check(c2.reads == r0 && out2.isEmpty() && work.size() == 1, "tick does not read on its own thread: one read handed to the worker");
            h2.runPending(); h2.runPending();
            check(work.size() == 1 && h2.pending != null, "while a read is outstanding, ticks keep running and hand out no second read");
            work.remove(0).run();
            check(c2.reads > r0 && out2.isEmpty() && back.size() == 1, "worker reads; result waits for the main executor");
            back.remove(0).run();
            check(out2.size() == 1 && Double.isNaN(out2.get(0)), "result published on main (first unplugged read is still settling)");
            SystemClock.now = 109000;
            h2.runPending(); work.remove(0).run(); back.remove(0).run();
            check(out2.size() == 2 && Math.abs(out2.get(1) - 4.0) < 0.000001, "next read after settle publishes 4 W");
            h2.runPending();                      // 派出一读，然后停表：这一读回来时必须丢掉
            stop.invoke(s2);
            work.remove(0).run(); back.remove(0).run();
            check(out2.size() == 2, "a read handed out before stop is dropped when it returns");
        }
        if (failures != 0) throw new AssertionError(failures + " sampler checks failed");
        System.out.println("BatteryManager settle / sign / plug transitions / stop / resume / readout switch passed");
    }
}
