package hy300;

import android.os.HwBinder;
import android.os.HwBlob;
import android.os.HwParcel;
import android.os.IHwBinder;
import android.os.SystemProperties;
import android.system.Os;
import android.system.StructPollfd;
import android.util.Log;
import java.io.File;
import java.io.FileInputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.file.Files;

/**
 * Keystone correction without the Magcubic launcher.
 *
 * The launcher (com.htc.magcubicos) sends four corner points to the vendor display HAL,
 * vendor.display.config@1.0::IDisplayConfig transaction 36, and saves them as eight
 * persist.display.keystone_* offsets (pixels inward from each panel corner), which the
 * display stack re-applies at boot. This does the same.
 *
 * Usage (root): CLASSPATH=keystone.dex app_process /system/bin hy300.Keystone <command>
 *   adjust   take over the IR remote: arrows change the keystone, OK saves, Back cancels
 *            (30 s without a key also cancels)
 *   show     print the saved offsets
 *   set ltx lty rtx rty lbx lby rbx rby
 *            apply offsets to the HAL without saving (testing)
 */
public final class Keystone {
    static final String TAG = "hy300-keystone";
    static final String HAL = "vendor.display.config@1.0::IDisplayConfig";
    static final int TRANSACT_SET_KEYSTONE = 36;
    // Offsets in the launcher's property order: left-top, right-top, left-bottom, right-bottom.
    static final String[] PROPS = {"ltx", "lty", "rtx", "rty", "lbx", "lby", "rbx", "rby"};

    // struct input_event on this 32-bit kernel: u32 tv_sec, u32 tv_usec, u16 type, u16 code, s32 value
    static final int EVENT_SIZE = 16;
    static final int EV_KEY = 1, EV_MSC = 4;
    static final int KEY_UP = 103, KEY_LEFT = 105, KEY_RIGHT = 106, KEY_DOWN = 108;
    static final int KEY_BACK = 158, KEY_OK = 352;
    static final int EVIOCGRAB = 0x40044590;  // _IOW('E', 0x90, int)
    static final short POLLIN = 1;
    static final int IDLE_MS = 30000;
    static final int STEP = 4, MAX_STEP = 16;  // pixels per press; held arrows speed up to MAX_STEP
    static final int PULSE = 24;               // extra inset of the "mode entered/saved" flash

    static int width, height;
    static IHwBinder hal;

    public static void main(String[] args) throws Exception {
        String[] size = SystemProperties.get("persist.vendor.disp.screensize", "1920x1080").split("x");
        width = Integer.parseInt(size[0]);
        height = Integer.parseInt(size[1]);
        String cmd = args.length > 0 ? args[0] : "";
        if (cmd.equals("show")) {
            int[] o = saved();
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < 8; i++) sb.append(PROPS[i]).append('=').append(o[i]).append(' ');
            System.out.println(sb.toString().trim());
        } else if (cmd.equals("set") && args.length == 9) {
            int[] o = new int[8];
            for (int i = 0; i < 8; i++) o[i] = Integer.parseInt(args[i + 1]);
            System.out.println(apply(o));
        } else if (cmd.equals("adjust")) {
            adjust();
        } else {
            System.err.println("usage: hy300.Keystone adjust | show | set ltx lty rtx rty lbx lby rbx rby");
            System.exit(2);
        }
    }

    static int[] saved() {
        int[] o = new int[8];
        for (int i = 0; i < 8; i++) o[i] = SystemProperties.getInt("persist.display.keystone_" + PROPS[i], 0);
        return o;
    }

    static void save(int[] o) {
        // Same properties the launcher writes (t3.d.c in com.htc.magcubicos).
        SystemProperties.set("persist.display.keystone_zoom_h", "100.0");
        SystemProperties.set("persist.display.keystone_zoom_v", "100.0");
        for (int i = 0; i < 8; i++) SystemProperties.set("persist.display.keystone_" + PROPS[i], Integer.toString(o[i]));
    }

    /** Sends offsets to the HAL as absolute corners, as the launcher does. Returns the HAL status (0 = ok). */
    static int apply(int[] o) throws Exception {
        if (hal == null) hal = HwBinder.getService(HAL, "default");
        int r = width - 1, b = height - 1;
        int[] pts = {o[0], o[1], r - o[2], o[3], o[4], b - o[5], r - o[6], b - o[7]};  // TL, TR, BL, BR
        HwParcel req = new HwParcel();
        req.writeInterfaceToken(HAL);
        req.writeFloat(100f);  // zoom h/v: the launcher always sends 100
        req.writeFloat(100f);
        for (int i = 0; i < 8; i += 2) {
            HwBlob p = new HwBlob(8);
            p.putInt32(0, pts[i]);
            p.putInt32(4, pts[i + 1]);
            req.writeBuffer(p);
        }
        HwParcel reply = new HwParcel();
        hal.transact(TRANSACT_SET_KEYSTONE, req, reply, 0);
        reply.verifySuccess();
        req.releaseTemporaryStorage();
        int status = reply.readInt32();
        reply.release();
        return status;
    }

    /**
     * The saved offsets are split into a base (zoom/position, kept as is) plus two keystone
     * amounts the arrows change:
     *   v > 0 pulls the top corners in (narrower top), v < 0 the bottom corners;
     *   h > 0 pulls the right corners in (shorter right edge), h < 0 the left corners.
     */
    static final class Shape {
        final int[] base;
        int v, h;

        Shape(int[] o) {
            base = o.clone();
            v = ((o[0] + o[2]) - (o[4] + o[6])) / 2;
            h = ((o[3] + o[7]) - (o[1] + o[5])) / 2;
            if (v > 0) { base[0] -= v; base[2] -= v; } else { base[4] += v; base[6] += v; }
            if (h > 0) { base[3] -= h; base[7] -= h; } else { base[1] += h; base[5] += h; }
        }

        int[] offsets(int extra) {
            int[] o = base.clone();
            if (v > 0) { o[0] += v; o[2] += v; } else { o[4] -= v; o[6] -= v; }
            if (h > 0) { o[3] += h; o[7] += h; } else { o[1] -= h; o[5] -= h; }
            for (int i = 0; i < 8; i++) {
                int max = (i % 2 == 0 ? width : height) / 3;
                o[i] = Math.max(0, Math.min(max, o[i] + extra));
            }
            return o;
        }

        void move(int key, int step) {
            if (key == KEY_UP) v = Math.min(v + step, width / 4);
            if (key == KEY_DOWN) v = Math.max(v - step, -width / 4);
            if (key == KEY_RIGHT) h = Math.min(h + step, height / 4);
            if (key == KEY_LEFT) h = Math.max(h - step, -height / 4);
        }
    }

    static String irDevice() throws Exception {
        File[] devs = new File("/sys/class/input").listFiles();
        if (devs != null) {
            for (File d : devs) {
                if (!d.getName().startsWith("event")) continue;
                File name = new File(d, "device/name");
                if (name.exists() && new String(Files.readAllBytes(name.toPath())).trim().equals("sunxi-ir")) {
                    return "/dev/input/" + d.getName();
                }
            }
        }
        throw new IllegalStateException("sunxi-ir input device not found");
    }

    static void pulse(Shape s) throws Exception {
        apply(s.offsets(PULSE));
        Thread.sleep(250);
        apply(s.offsets(0));
    }

    static void adjust() throws Exception {
        int[] start = saved();
        Shape s = new Shape(start);
        String dev = irDevice();
        // The grab keeps the remote's keys away from Android until this stream is closed.
        try (FileInputStream in = new FileInputStream(dev)) {
            Os.ioctlInt(in.getFD(), EVIOCGRAB);
            Log.i(TAG, "adjust: started on " + dev + ", v=" + s.v + " h=" + s.h);
            pulse(s);
            ByteBuffer buf = ByteBuffer.allocate(EVENT_SIZE * 64).order(ByteOrder.LITTLE_ENDIAN);
            StructPollfd pfd = new StructPollfd();
            pfd.fd = in.getFD();
            pfd.events = POLLIN;
            int held = -1, scans = 0, exitKey = -1;
            while (true) {
                if (Os.poll(new StructPollfd[] {pfd}, IDLE_MS) == 0) {
                    if (exitKey < 0) {
                        apply(start);
                        Log.i(TAG, "adjust: idle, reverted");
                    }
                    return;
                }
                int n = in.read(buf.array());
                for (int off = 0; off + EVENT_SIZE <= n; off += EVENT_SIZE) {
                    int type = buf.getShort(off + 8) & 0xffff, code = buf.getShort(off + 10) & 0xffff;
                    int value = buf.getInt(off + 12);
                    if (type == EV_KEY && value == 1 && exitKey < 0) {
                        held = code;
                        scans = 0;
                        if (code == KEY_OK) {
                            int[] o = s.offsets(0);
                            save(o);
                            pulse(s);
                            Log.i(TAG, "adjust: saved v=" + s.v + " h=" + s.h);
                            exitKey = code;
                        } else if (code == KEY_BACK) {
                            apply(start);
                            Log.i(TAG, "adjust: cancelled");
                            exitKey = code;
                        } else {
                            s.move(code, STEP);
                            apply(s.offsets(0));
                        }
                    } else if (type == EV_KEY && value == 0) {
                        if (code == exitKey) return;  // leave after the release, so Android never sees half a press
                        if (code == held) held = -1;
                    } else if (type == EV_MSC && held >= 0 && exitKey < 0) {
                        // A held IR key repeats only its scancode (about every 108 ms); the first one
                        // follows the press within ~50 ms, so start repeating from the second.
                        if (++scans >= 2) {
                            s.move(held, Math.min(STEP + 2 * (scans - 2), MAX_STEP));
                            apply(s.offsets(0));
                        }
                    }
                }
            }
        }
    }
}
