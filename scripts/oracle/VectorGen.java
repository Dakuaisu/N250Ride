package com.bajajnav.relay;

import java.util.ArrayList;
import java.util.List;

/**
 * Development-only golden-vector generator. Runs the pinned, unmodified upstream
 * TbtFrame / GeneralPacket encoders over synthetic inputs and prints JSON on
 * stdout. Output is deterministic: no clock, locale or random input.
 *
 * Usage: java com.bajajnav.relay.VectorGen <upstream-commit>
 */
public final class VectorGen {
    private static final List<String> tbt = new ArrayList<>();
    private static final List<String> general = new ArrayList<>();
    /** Mirrors GeneralPacket's private static heartbeat (pre-incremented per build). */
    private static int builds = 0;

    private VectorGen() {
    }

    public static void main(String[] args) {
        String commit = args.length > 0 ? args[0] : "unknown";

        tbtVector("start", 1, TbtFrame.STRAIGHT, true, 0, 0, 0, 0, 0, "");
        tbt.add(entry("stop", 0, 0, true, 0, 0, 0, 0, 0, "", TbtFrame.stop()));

        int[] distances = {0, 1, 99, 100, 999, 1000, 1010, 1100, 1999, 4350, 12345, 65535999};
        for (int d : distances) {
            tbtVector("step-" + d, 1, TbtFrame.TURN_LEFT, true, d, 5000, 10, 15, 0, "MG Road");
            tbtVector("total-" + d, 1, TbtFrame.TURN_RIGHT, true, 250, d, 10, 15, 0, "MG Road");
        }

        tbtVector("noon-pm", 1, TbtFrame.TURN_RIGHT, false, 250, 4200, 12, 0, 0, "");
        tbtVector("midnight-am", 1, TbtFrame.TURN_RIGHT, true, 250, 4200, 12, 0, 0, "");
        tbtVector("1-59-am", 1, TbtFrame.STRAIGHT, true, 250, 4200, 1, 59, 0, "");
        tbtVector("11-45-pm", 1, TbtFrame.STRAIGHT, false, 250, 4200, 11, 45, 0, "");

        String[] texts = {
                "",
                null,
                "Brigade Road",
                "M.G. Road, 2nd-Cross",
                "Rua S\u00e3o Jo\u00e3o",
                "Ring Road \uD83D\uDE00 exit",
                "ABCDEFGHIJKLMNOPQRSTUVWXYZ01234",
                "Outer Ring Road towards Silk Board Junction",
                "   padded   ",
                "\u0928\u092e\u0938\u094d\u0924\u0947",
                "Cafe\u0301 Street",
        };
        for (int i = 0; i < texts.length; i++) {
            tbtVector("text-" + i, 1, TbtFrame.STRAIGHT, true, 250, 4200, 3, 5, 0, texts[i]);
        }

        for (int exit = 1; exit <= 7; exit++) {
            tbtVector("roundabout-right-exit-" + exit, 1, TbtFrame.ROUNDABOUT_RIGHT, true, 300, 4200, 4, 20, exit, "");
            tbtVector("roundabout-left-exit-" + exit, 1, TbtFrame.ROUNDABOUT_LEFT, true, 300, 4200, 4, 20, exit, "");
        }

        int[] icons = {
                TbtFrame.WRONG_WAY, TbtFrame.SLIGHT_LEFT, TbtFrame.SLIGHT_RIGHT, TbtFrame.SHARP_LEFT,
                TbtFrame.SHARP_RIGHT, TbtFrame.STRAIGHT, TbtFrame.DEST_REACHED, TbtFrame.TURN_LEFT,
                TbtFrame.TURN_RIGHT, TbtFrame.RAMP_LEFT, TbtFrame.RAMP_RIGHT, TbtFrame.ROUNDABOUT_RIGHT,
                TbtFrame.U_TURN_LEFT, TbtFrame.U_TURN_RIGHT, TbtFrame.FORK_LEFT, TbtFrame.FORK_RIGHT,
                TbtFrame.FERRY_TRAIN, TbtFrame.ROUNDABOUT_LEFT, TbtFrame.MERGE, TbtFrame.KEEP_RIGHT,
                TbtFrame.FERRY, TbtFrame.KEEP_LEFT,
        };
        for (int icon : icons) {
            tbtVector("icon-" + icon, 1, icon, true, 250, 4200, 9, 30, 0, "");
            tbtVector("icon-" + (icon + 32), 1, icon + 32, true, 60, 4010, 9, 30, 0, "");
        }

        GeneralPacket.volume = 5;
        GeneralPacket.battery = 3;
        for (int i = 0; i < 3; i++) {
            generalVector("legacy55-default-" + i, GeneralPacket.MODE_LEGACY55, "legacy55");
        }
        for (int i = 0; i < 3; i++) {
            generalVector("v2-default-" + i, GeneralPacket.MODE_V2_89, "v2_89");
        }
        for (int battery = 0; battery <= 4; battery++) {
            GeneralPacket.battery = battery;
            generalVector("legacy55-battery-" + battery, GeneralPacket.MODE_LEGACY55, "legacy55");
            generalVector("v2-battery-" + battery, GeneralPacket.MODE_V2_89, "v2_89");
        }
        GeneralPacket.battery = 3;
        for (int volume : new int[]{0, 15}) {
            GeneralPacket.volume = volume;
            generalVector("legacy55-volume-" + volume, GeneralPacket.MODE_LEGACY55, "legacy55");
            generalVector("v2-volume-" + volume, GeneralPacket.MODE_V2_89, "v2_89");
        }
        GeneralPacket.volume = 5;
        while (builds < 253) {
            GeneralPacket.build(GeneralPacket.MODE_V2_89);
            builds++;
        }
        for (int i = 0; i < 4; i++) {
            generalVector("v2-heartbeat-wrap-" + i, GeneralPacket.MODE_V2_89, "v2_89");
            generalVector("legacy55-heartbeat-wrap-" + i, GeneralPacket.MODE_LEGACY55, "legacy55");
        }

        StringBuilder out = new StringBuilder();
        out.append("{\n");
        out.append("  \"upstreamCommit\": ").append(str(commit)).append(",\n");
        out.append("  \"generator\": \"scripts/oracle/VectorGen.java\",\n");
        out.append("  \"tbt\": [\n").append(String.join(",\n", tbt)).append("\n  ],\n");
        out.append("  \"general\": [\n").append(String.join(",\n", general)).append("\n  ]\n");
        out.append("}\n");
        System.out.print(out);
    }

    private static void tbtVector(String name, int type, int icon, boolean am, int step, int total,
                                  int hour, int minute, int exit, String text) {
        byte[] frame = TbtFrame.build(type, icon, am, step, total, hour, minute, exit, text);
        tbt.add(entry(name, type, icon, am, step, total, hour, minute, exit, text, frame));
    }

    private static String entry(String name, int type, int icon, boolean am, int step, int total,
                                int hour, int minute, int exit, String text, byte[] frame) {
        return "    {\"name\": " + str(name)
                + ", \"type\": " + type
                + ", \"icon\": " + icon
                + ", \"am\": " + am
                + ", \"stepMetres\": " + step
                + ", \"totalMetres\": " + total
                + ", \"etaHour\": " + hour
                + ", \"etaMinute\": " + minute
                + ", \"roundaboutExit\": " + exit
                + ", \"text\": " + (text == null ? "null" : str(text))
                + ", \"hex\": " + str(hex(frame)) + "}";
    }

    private static void generalVector(String name, int mode, String profile) {
        int volume = GeneralPacket.volume;
        int battery = GeneralPacket.battery;
        byte[] packet = GeneralPacket.build(mode);
        builds++;
        general.add("    {\"name\": " + str(name)
                + ", \"profile\": " + str(profile)
                + ", \"volume\": " + volume
                + ", \"battery\": " + battery
                + ", \"heartbeat\": " + (builds & 0xFF)
                + ", \"model\": " + str(android.os.Build.MODEL)
                + ", \"hex\": " + str(hex(packet)) + "}");
    }

    private static String hex(byte[] a) {
        StringBuilder sb = new StringBuilder();
        for (byte x : a) {
            sb.append(String.format("%02X", x & 0xFF));
        }
        return sb.toString();
    }

    private static String str(String s) {
        StringBuilder sb = new StringBuilder("\"");
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c == '"' || c == '\\') {
                sb.append('\\').append(c);
            } else if (c < 0x20 || c > 0x7E) {
                sb.append(String.format("\\u%04x", (int) c));
            } else {
                sb.append(c);
            }
        }
        return sb.append('"').toString();
    }
}
