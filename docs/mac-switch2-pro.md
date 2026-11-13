# Mac Switch 2 Pro input

The `S2ArmNS2Connection` helper bundled next to the S2Arm launcher owns the
CoreBluetooth connection. The game receives input over a private Unix-domain socket, so the
launcher and game never compete for the same physical controller link. This
does not create a virtual device or synthesize keyboard events. The shared
transport retains its original protocol implementation and license.

## Use

1. Open S2Arm. Quit InputConfig or any other app connected to this controller.
2. Open **手柄** in the S2Arm toolbar and press **连接手柄**. Wake the controller.
   On first use, hold SYNC and approve the macOS Bluetooth prompt. The launcher
   reports **已连接** after calibration and initialization.
3. Start the game as usual. S2Arm keeps the Bluetooth connection while the game
   uses the private input relay. If the controller is disconnected and
   reconnected from S2Arm while the game runs, the game shows a one-time notice
   and reattaches to the relay automatically.
4. Closing the game leaves the controller connected by default. Turn on
   **关闭游戏后自动断开手柄** to disconnect it when a game exits.
5. The running game's **输入** menu remains a manual fallback:
   **连接 / 重试 Switch 2 Pro…**. **测试手柄震动** sends a 250 ms left/right
   test through the same rumble mapping as the game.

Switch 2 Pro rumble uses the same strength mapping as other Mac controllers:
each band's game amplitude passes through `s2a_hp_feel`, then the launch
setting **震动强度** (`S2A_RUMBLE_SCALE`) multiplies it, capped at 1.
Frequencies, left/right channels, leases and stop commands are unchanged.

The controller popover has three independent persisted settings:
**开启 S2Arm 时自动连接手柄**, **关闭游戏后自动断开手柄** and **记住这台设备**. All
default to off, so opening S2Arm does not start Bluetooth scanning or show a pairing prompt.

**记住这台设备** (Pro controller and Joy-Con 2): with it on, a controller that
connects in pairing mode (SYNC held until the player lights sweep) is given this
Mac's Bluetooth address with the controller's own bonding commands. After that a
press of any button wakes it toward this Mac and it reconnects without SYNC: the
helper keeps a connection request open for a controller bonded here, also after
it disconnects. A controller remembers one host at a time; after it is used with
a console or another computer, hold SYNC again here. If the Mac's address cannot
be read or the controller does not answer a bonding command, the helper logs it
and the controller works as before for this session. Changing the setting
restarts the helper unless a game is using the controller. iOS has no API for the
device's own Bluetooth address, so this is Mac only.
Manual **连接手柄** and **断开连接** controls are always available in the
popover. Play remains available without a controller. With no relay socket, the
launch request tells the game not to run its own background controller check.
The helper watches the launcher with kqueue and exits if the launcher crashes or
is force quit, so a stale process cannot keep the Bluetooth link.

All 16 standard Nintendo buttons and both analog sticks use the game's existing
controller mappings and deadzone. Home, Capture and C are not game inputs.
In the S2Arm launcher, open the game's **更多 → 手柄设置** and use the
**Switch 2 Pro 背键** section. GL and GR independently emulate any standard
controller button or remain unbound. Save together with the rest of the game's
input configuration; the next game launch reads the same frozen config snapshot.
Original button bindings remain available. The running game has no back-button
settings menu. Older configs without `backButtons` leave both paddles disabled.
Paddle and physical presses are combined, so releasing one never cancels the other.
The explicitly connected BLE controller takes precedence over system gamepads;
keyboard and mouse remain available. The first connection and retries remain available in the menu.

Game six-axis requests control the IMU. Samples keep the existing transport's
g / degrees-per-second units, device axes and timestamp, feeding the existing
`ControllerFeedback` orientation integration. Left and right game vibration
frames feed the transport's atomic pair mailbox, including their frequencies.
Focus loss stops vibration, hides sensor/input snapshots and changes the feedback
session; disconnect clears the input state. Connection remains alive when merely
switching windows so it can resume without pairing again.

Both the game bundle and its parent launcher need
`NSBluetoothAlwaysUsageDescription` in `Contents/Info.plist`: macOS attributes the
controller helper's Bluetooth request to the launcher. Omitting the launcher's
key terminates the helper instead of showing the consent prompt.

`launchers/macos/build_app.py` builds the helper with
`make S2A_MAC_FRONTEND=1 build/S2ArmNS2Connection`, copies it into
`Contents/MacOS`, and adds `NSBluetoothAlwaysUsageDescription` to the launcher.
Prepared games get the same key from `pack/jobs/build.py`. During launcher
development, the helper is also found at `build/S2ArmNS2Connection`.

## Verification

`make native-test-mac_ns2 native-test-ns2pro` covers the new host bridge and the
existing captured-report/rumble codecs without connecting to hardware. Real
Bluetooth permission, pairing, physical vibration, and in-game motion still need
a live controller; passing codec tests alone does not establish those outcomes.
