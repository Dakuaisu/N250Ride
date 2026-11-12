package com.bajajnav.relay;

/**
 * Oracle-only stand-in for upstream PhoneBridge. N250Ride mirrors no calls, so
 * every phone field is the neutral "no call" value; constants match upstream.
 */
final class PhoneBridge {
    static final int CALL_NONE = 0;
    static final int CALL_INCOMING = 1;
    static final int CALL_OUTGOING = 2;
    static final int CALL_ACTIVE = 3;
    static final int CALL_ENDED = 4;

    private static final PhoneBridge INSTANCE = new PhoneBridge();

    static PhoneBridge get() {
        return INSTANCE;
    }

    int callState() {
        return CALL_NONE;
    }

    String callerName() {
        return "";
    }

    int missedCount() {
        return 0;
    }

    int missedCallGetAck() {
        return 0;
    }

    int callAcceptAck() {
        return 0;
    }

    int callRejectAck() {
        return 0;
    }

    int callRejectSmsAck() {
        return 0;
    }

    int nextCallProgress() {
        return 0;
    }
}
