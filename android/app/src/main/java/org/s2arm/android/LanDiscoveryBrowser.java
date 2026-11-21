package org.s2arm.android;

import android.net.nsd.NsdManager;
import android.net.nsd.NsdServiceInfo;
import android.os.Handler;
import android.util.Log;
import java.net.Inet4Address;
import java.util.ArrayDeque;

/** API-29 NSD discovery adapter. One legacy resolve at a time; no election policy here. */
final class LanDiscoveryBrowser {
    static final String TYPE = "_s2arm-ldn._tcp.";
    private final NsdManager manager;
    private final Handler handler;
    private final LanDiscoverySession session;
    private volatile Run run;
    Runnable cleaned = () -> {};
    Runnable failed = () -> {};
    private volatile int pendingCleanup;
    boolean idle() { return run == null && pendingCleanup == 0 && retiring.isEmpty(); }
    // Legacy NSD permits only one resolve, even across a stop/start boundary. Handler-owned.
    private Pending inFlight;
    private final java.util.ArrayList<Run> retiring = new java.util.ArrayList<>();

    // Changed must only do nonblocking publication; it must not re-enter browser start/stop.
    LanDiscoveryBrowser(NsdManager manager, Handler handler, LanDiscoverySession.Changed changed) {
        this.manager = manager;
        this.handler = handler;
        session = new LanDiscoverySession(changed);
    }

    synchronized void start(String prefix) {
        if (run != null) return;
        Run next = new Run(session.start(), prefix);
        run = next;
        handler.post(() -> { retryCleanup(); next.start(); });
    }

    synchronized void stop() {
        session.stop();
        Run previous = run;
        run = null;
        if (previous != null) {
            previous.stopped = true;
            pendingCleanup++;
            handler.post(() -> { pendingCleanup--; retiring.add(previous); retryCleanup(); });
        } else handler.post(this::retryCleanup);
    }

    private void retryCleanup() {
        for (Run previous : new java.util.ArrayList<>(retiring)) previous.stop();
        if (idle()) cleaned.run();
    }

    private final class Pending {
        final NsdServiceInfo service;
        final LanDiscoverySession.Resolve ticket;
        Pending(NsdServiceInfo service, LanDiscoverySession.Resolve ticket) {
            this.service = service; this.ticket = ticket;
        }
    }

    private final class Run implements NsdManager.DiscoveryListener {
        final long generation;
        final String prefix;
        final ArrayDeque<Pending> queue = new ArrayDeque<>();
        volatile boolean stopped;
        boolean discovering;
        boolean stopping;
        Run(long generation, String prefix) { this.generation = generation; this.prefix = prefix; }
        void start() {
            if (stopped) return;
            try {
                manager.discoverServices(TYPE, NsdManager.PROTOCOL_DNS_SD, this);
                discovering = true;
            } catch (RuntimeException e) { startFailed(e.toString()); }
        }
        void stop() {
            queue.clear();
            if (!discovering) { retiring.remove(this); return; }
            if (stopping) return;
            stopping = true;
            try { manager.stopServiceDiscovery(this); }
            catch (RuntimeException e) {
                stopping = false;
                Log.e("S2Arm", "NSD stop: " + e);
            }
        }
        void startFailed(String detail) {
            discovering = false;
            stopped = true;
            queue.clear();
            boolean current;
            synchronized (LanDiscoveryBrowser.this) {
                current = run == this;
                if (current) {
                    run = null;
                    session.stop();
                }
            }
            fail("start", detail);
            retiring.remove(this);
            if (current) failed.run();
            if (idle()) cleaned.run();
        }
        void fail(String operation, String detail) {
            Log.e("S2Arm", "NSD " + operation + ": " + detail);
        }
        public void onDiscoveryStarted(String type) { }
        public void onDiscoveryStopped(String type) {
            handler.post(() -> { discovering = false; stopping = false; retiring.remove(this); if (idle()) cleaned.run(); });
        }
        public void onStartDiscoveryFailed(String type, int error) {
            handler.post(() -> startFailed(Integer.toString(error)));
        }
        public void onStopDiscoveryFailed(String type, int error) {
            handler.post(() -> { stopping = false; fail("stop", Integer.toString(error)); });
        }
        public void onServiceFound(NsdServiceInfo service) {
            handler.post(() -> {
                if (stopped || !service.getServiceName().startsWith(prefix)) return;
                LanDiscoverySession.Resolve ticket = session.found(generation, service.getServiceName());
                if (ticket == null) return;
                queue.add(new Pending(service, ticket));
                resolveNext();
            });
        }
        public void onServiceLost(NsdServiceInfo service) {
            handler.post(() -> session.lost(generation, service.getServiceName()));
        }
        void resolveNext() {
            if (stopped || inFlight != null || queue.isEmpty()) return;
            Pending pending = queue.remove();
            inFlight = pending;
            try {
                manager.resolveService(pending.service, handler::post, new NsdManager.ResolveListener() {
                    public void onResolveFailed(NsdServiceInfo service, int error) {
                        finish(pending, null, 0);
                    }
                    public void onServiceResolved(NsdServiceInfo service) {
                        String address = service.getHost() instanceof Inet4Address
                            ? service.getHost().getHostAddress() : null;
                        finish(pending, address, service.getPort());
                    }
                });
            } catch (RuntimeException e) {
                fail("resolve", e.toString());
                finish(pending, null, 0);
            }
        }
        void finish(Pending pending, String address, int port) {
            if (inFlight != pending) return;
            inFlight = null;
            if (address == null || port < 1 || port > 65535) session.failed(pending.ticket);
            else session.resolved(pending.ticket, address, port);
            Run current = run;
            if (current != null) current.resolveNext();
        }
    }
}
