package org.s2arm.android;

import android.content.SharedPreferences;
import android.hardware.Sensor;
import android.hardware.SensorEvent;
import android.hardware.SensorEventListener;
import android.hardware.SensorManager;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.Looper;
import android.os.VibrationEffect;
import android.os.Vibrator;
import android.util.Log;
import android.view.InputDevice;
import android.view.KeyEvent;

/**
 * Player 1's physical controller: its own rumble motors and six-axis sensors (#528 item 10, piece 2), as iOS
 * ios/controller.m does for system controllers. Native side: native/phone_feedback.c decides who rumbles
 * (controller with a motor > phone motor) and whose six-axis the game reads (controller with samples > phone,
 * runtime/src/motion_pick.c); this class only owns the Android objects the NDK has no API for.
 *
 * <p>Which controller: the one that last sent a key or stick event, else the first attached gamepad (Android merges
 * every controller into player 1, see MainActivity.publishInput). Motors: InputDevice.getVibratorManager (API 31,
 * id 0 = left / strong, id 1 = right / weak) or InputDevice.getVibrator before that. Sensors: InputDevice
 * .getSensorManager (API 31 only), registered only while the game wants six-axis and the activity is resumed.
 */
final class PadFeedback {
    static final String PREF_RUMBLE = "pad_rumble";
    private static final String TAG = "S2Arm";
    private static final int SENSOR_PERIOD_US = 5000;   // 200 Hz, as the phone sensors

    /** Motors of the chosen controller; immutable, read on the native rumble thread. */
    private static final class Motors {
        final Vibrator single;          // API < 31, or a manager with a single motor
        final Object manager;           // android.os.VibratorManager on API 31+ with two motors
        final int[] ids;
        final boolean amplitude;
        Motors(Vibrator single, Object manager, int[] ids) {
            this.single = single; this.manager = manager; this.ids = ids;
            this.amplitude = single == null || single.hasAmplitudeControl();
        }
    }

    private static volatile Motors motors;             // null: no controller motor, or the player turned it off
    private static volatile boolean motionWanted;      // the game asked for six-axis (native, any thread)
    private static volatile PadFeedback current;       // resumed instance, for motionWanted

    private final SharedPreferences prefs;
    private final Handler main = new Handler(Looper.getMainLooper());
    private int deviceId = -1;                         // controller published to native
    private int lastInputId = -1;                      // controller that last sent input
    private boolean hasMotor, resumed;
    private SensorManager sensorManager;               // registered on, or null
    private HandlerThread sensorThread;
    private final SensorEventListener listener = new SensorEventListener() {
        @Override public void onSensorChanged(SensorEvent event) {
            float[] v = event.values;
            if (v.length < 3) return;
            NativeBridge.padSensor(event.sensor.getType() == Sensor.TYPE_GYROSCOPE, v[0], v[1], v[2]);
        }
        @Override public void onAccuracyChanged(Sensor sensor, int accuracy) { }
    };

    PadFeedback(SharedPreferences prefs) { this.prefs = prefs; }

    /** Same test MainActivity uses to hide the on-screen pad: a real gamepad with an A button. */
    static boolean isGamepad(InputDevice device) {
        if (device == null || device.isVirtual()) return false;
        int source = device.getSources();
        boolean controller = (source & InputDevice.SOURCE_GAMEPAD) == InputDevice.SOURCE_GAMEPAD
            || (source & InputDevice.SOURCE_JOYSTICK) == InputDevice.SOURCE_JOYSTICK;
        // 只认真有手柄按键（A 键）的设备：有的手机自带一个报 JOYSTICK 来源的内置传感设备（只有 X / Y 轴、没有手柄按键）
        return controller && device.hasKeys(KeyEvent.KEYCODE_BUTTON_A)[0];
    }

    boolean rumble() { return prefs.getBoolean(PREF_RUMBLE, true); }
    /** The chosen controller has a motor (whether or not the player turned controller rumble off): menu item shows. */
    boolean hasMotor() { return hasMotor; }
    void setRumble(boolean on) { prefs.edit().putBoolean(PREF_RUMBLE, on).apply(); publish(); }

    /** Main thread, every controller key / stick event: cheap unless the driving controller changed. */
    void noteInput(InputDevice device) {
        if (device == null || device.getId() == lastInputId) return;
        lastInputId = device.getId();
        if (resumed && lastInputId != deviceId) publish();
    }

    void resume() {
        resumed = true;
        current = this;
        publish();
    }
    void pause() {
        resumed = false;
        if (current == this) current = null;
        updateSensors();
        Motors m = motors;
        if (m != null) cancel(m);   // native also stops on background; this one does not wait for the mailbox
    }

    /** Main thread: choose player 1's controller, tell native what it can do, follow with the sensors. */
    void publish() {
        InputDevice chosen = InputDevice.getDevice(lastInputId);
        if (!isGamepad(chosen)) {
            chosen = null;
            for (int id : InputDevice.getDeviceIds()) {
                InputDevice d = InputDevice.getDevice(id);
                if (isGamepad(d)) { chosen = d; break; }
            }
        }
        int id = chosen != null ? chosen.getId() : -1;
        boolean changed = id != deviceId;
        if (changed && sensorManager != null) unregister();   // the old controller's sensors, before the new one's
        deviceId = id;
        Motors found = chosen != null ? motorsOf(chosen) : null;
        hasMotor = found != null;
        Motors old = motors;
        motors = found != null && rumble() ? found : null;
        if (old != null && motors == null) cancel(old);
        boolean motion = chosen != null && sensorsOf(chosen) != null;
        NativeBridge.configurePadFeedback(motors != null, chosen != null ? chosen.getVendorId() : 0, motion, changed);
        if (changed) Log.i(TAG, "Controller for rumble / six-axis: " + (chosen == null ? "none"
            : chosen.getName() + String.format(java.util.Locale.ROOT, " (%04x:%04x)", chosen.getVendorId(), chosen.getProductId())
              + ", motor " + hasMotor + ", sensors " + motion));
        updateSensors();
    }

    @SuppressWarnings("deprecation")
    private static Motors motorsOf(InputDevice device) {
        android.os.VibratorManager manager = device.getVibratorManager();
        int[] ids = manager.getVibratorIds();
        if (ids.length >= 2) return new Motors(null, manager, ids);
        if (ids.length == 1) {
            Vibrator v = manager.getVibrator(ids[0]);
            return v.hasVibrator() ? new Motors(v, null, ids) : null;
        }
        return null;
    }

    /** The controller's sensor manager when it has both an accelerometer and a gyroscope. */
    private static SensorManager sensorsOf(InputDevice device) {
        SensorManager manager = device.getSensorManager();
        return manager.getDefaultSensor(Sensor.TYPE_ACCELEROMETER) != null
            && manager.getDefaultSensor(Sensor.TYPE_GYROSCOPE) != null ? manager : null;
    }

    /** Native (phone_feedback.c s2a_pad_set_motion_enabled), any thread. */
    static void motionWanted(boolean wanted) {
        motionWanted = wanted;
        PadFeedback p = current;
        if (p != null) p.main.post(p::updateSensors);
    }

    /** Main thread: controller sensors on only while the game wants six-axis and we are in front. */
    private void updateSensors() {
        InputDevice device = resumed && motionWanted ? InputDevice.getDevice(deviceId) : null;
        SensorManager want = device != null ? sensorsOf(device) : null;
        if (want == null) { if (sensorManager != null) unregister(); return; }
        if (sensorManager != null) return;   // already on (a changed controller unregistered in publish)
        if (sensorThread == null) { sensorThread = new HandlerThread("S2Arm pad sensors"); sensorThread.start(); }
        Handler handler = new Handler(sensorThread.getLooper());
        boolean a = want.registerListener(listener, want.getDefaultSensor(Sensor.TYPE_ACCELEROMETER), SENSOR_PERIOD_US, handler);
        boolean g = want.registerListener(listener, want.getDefaultSensor(Sensor.TYPE_GYROSCOPE), SENSOR_PERIOD_US, handler);
        sensorManager = want;
        if (!a || !g) Log.e(TAG, "【红】手柄六轴：开传感器失败（加速度计 " + a + "、陀螺仪 " + g + "），体感走手机陀螺仪");
        else Log.i(TAG, "手柄六轴：开（" + device.getName() + "，200 Hz）");
    }

    private void unregister() {
        // Whole listener at once: InputDeviceSensorManager's per-sensor removal can throw
        // ConcurrentModificationException (AOSP bug, noted by Dolphin's DolphinSensorEventListener).
        try { sensorManager.unregisterListener(listener); }
        catch (RuntimeException e) { Log.e(TAG, "Controller sensors: unregister failed", e); }
        sensorManager = null;
        Log.i(TAG, "手柄六轴：关");
    }

    private static void cancel(Motors m) {
        try {
            if (m.single != null) m.single.cancel();
            else ((android.os.VibratorManager) m.manager).cancel();
        } catch (RuntimeException e) { Log.e(TAG, "Controller rumble: cancel failed", e); }
    }

    private static boolean failed;
    /**
     * Called from native (phone_feedback.c, rumble mailbox thread): left / right amplitude 0..255 start a one-shot
     * of leaseMs on each motor (renewed by native while the game keeps rumbling, so a stuck process stops within
     * the lease); both 0 cancel. A new vibration replaces the previous one on the device.
     */
    static void vibrate(int left, int right, int leaseMs) {
        Motors m = motors;
        if (m == null) return;
        try {
            if (left <= 0 && right <= 0) { cancel(m); return; }
            if (m.single == null) {
                android.os.CombinedVibration.ParallelCombination both = android.os.CombinedVibration.startParallel();
                if (left > 0) both.addVibrator(m.ids[0], VibrationEffect.createOneShot(leaseMs, Math.min(255, left)));
                if (right > 0) both.addVibrator(m.ids[1], VibrationEffect.createOneShot(leaseMs, Math.min(255, right)));
                ((android.os.VibratorManager) m.manager).vibrate(both.combine());
                return;
            }
            int amplitude = Math.min(255, Math.max(left, right));
            // On/off motors: weak requests would come out at full strength, so they stay off (as PhoneFeedback).
            if (!m.amplitude && amplitude < 32) { cancel(m); return; }
            m.single.vibrate(VibrationEffect.createOneShot(leaseMs, m.amplitude ? amplitude : VibrationEffect.DEFAULT_AMPLITUDE));
        } catch (RuntimeException e) {
            if (!failed) { failed = true; Log.e(TAG, "【红】手柄震动：下发失败（只报一次）", e); }
        }
    }
}
