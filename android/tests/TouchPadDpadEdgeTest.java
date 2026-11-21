// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
package org.s2arm.android;

/** Ordinary editor drags and round trips through the production F01 model. */
public final class TouchPadDpadEdgeTest {
    private static final String[] DIRECTIONS = {"UP", "DOWN", "LEFT", "RIGHT"};
    private static int checks, failures;

    private static void close(double observed, double expected, String label) {
        checks++;
        if (Math.abs(observed - expected) > 0.001) {
            failures++;
            System.err.printf("FAIL: %s: %.5f != %.5f%n", label, observed, expected);
        }
    }

    private static void edge(int xDir, int yDir, double scale) {
        TouchPad pad = new TouchPad();
        final float left = 19, top = 27, width = 1280, height = 720;
        TouchLayout start = TouchLayout.androidDefault(width, height).withButtonScale(scale);
        pad.setLayout(start);
        pad.layout(left, top, width, height);
        String label = "edge " + xDir + "," + yDir + " scale " + scale;
        for (int round = 0; round < 3; round++) {
            TouchPad.Control dpad = pad.controls().stream().filter(c -> c.kind == TouchPad.DPAD)
                    .findFirst().orElseThrow();
            float x = xDir == 0 ? dpad.x : xDir < 0 ? left - 20 : left + width + 20;
            float y = yDir == 0 ? dpad.y : yDir < 0 ? top - 20 : top + height + 20;
            pad.moveControl(dpad, x, y);
            double dx = dpad.x - dpad.homeX, dy = dpad.y - dpad.homeY;
            TouchLayout saved = TouchLayout.read(pad.editedLayout("edge-test", "Edge Test").jsonBytes());
            double[] before = start.dpad(left, top, width, height);
            double[] after = saved.dpad(left, top, width, height);
            close(after[0], dpad.x, label + " preview x");
            close(after[1], dpad.y, label + " preview y");
            close(after[2], before[2], label + " radius");
            double minX = left + width, maxX = left, minY = top + height, maxY = top;
            for (String key : DIRECTIONS) {
                TouchLayout.Button old = start.button(key), now = saved.button(key);
                close((now.x - old.x) * width, dx, label + " " + key + " dx");
                close((now.y - old.y) * height, dy, label + " " + key + " dy");
                close(now.width, old.width, label + " button width");
                close(now.height, old.height, label + " button height");
                TouchLayout.Rect frame = saved.frameForButton(key, left, top, width, height);
                minX = Math.min(minX, frame.x); maxX = Math.max(maxX, frame.x + frame.width);
                minY = Math.min(minY, frame.y); maxY = Math.max(maxY, frame.y + frame.height);
            }
            if (xDir != 0) close(xDir < 0 ? minX : maxX, xDir < 0 ? left : left + width, label + " reaches x boundary");
            if (yDir != 0) close(yDir < 0 ? minY : maxY, yDir < 0 ? top : top + height, label + " reaches y boundary");
            start = saved;
            pad.setLayout(saved);
            pad.layout(left, top, width, height);
        }
    }

    public static void main(String[] args) {
        for (double scale : new double[] {1.0, 1.25})
            for (int x = -1; x <= 1; x++)
                for (int y = -1; y <= 1; y++)
                    if (x != 0 || y != 0) edge(x, y, scale);
        System.out.printf("TouchPad D-pad edges: %d checks, %d failures%n", checks, failures);
        if (failures != 0) System.exit(1);
    }
}
