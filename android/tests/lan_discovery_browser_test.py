#!/usr/bin/env python3
"""Production NSD adapter callback tests. Android API behavior is fake, not device evidence."""
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
JAVAC = pathlib.Path(subprocess.check_output(['bash', str(ROOT / 'tools/jdk17.sh')], text=True).strip())
JAVA = JAVAC.parent / 'java'
STUBS = {
'android/os/Handler.java': '''package android.os;
public class Handler { private final java.util.ArrayDeque<Runnable> q=new java.util.ArrayDeque<>();
 public boolean post(Runnable r){q.add(r);return true;} public void drain(){while(!q.isEmpty())q.remove().run();} }
''',
'android/util/Log.java': '''package android.util; public class Log { public static int e(String t,String s){return 0;} }''',
'android/net/nsd/NsdServiceInfo.java': '''package android.net.nsd;
public class NsdServiceInfo { private final String name; private final java.net.InetAddress host;
 public NsdServiceInfo(String n,String h) throws Exception{name=n;host=java.net.InetAddress.getByName(h);}
 public int getPort(){return 31337;} public String getServiceName(){return name;} public java.net.InetAddress getHost(){return host;} }
''',
'android/net/nsd/NsdManager.java': '''package android.net.nsd;
public class NsdManager { public static final int PROTOCOL_DNS_SD=1;
 public interface DiscoveryListener {void onDiscoveryStarted(String s);void onDiscoveryStopped(String s);
 void onStartDiscoveryFailed(String s,int e);void onStopDiscoveryFailed(String s,int e);
 void onServiceFound(NsdServiceInfo s);void onServiceLost(NsdServiceInfo s);}
 public interface ResolveListener {void onResolveFailed(NsdServiceInfo s,int e);void onServiceResolved(NsdServiceInfo s);}
 public DiscoveryListener discovery; public ResolveListener resolve; public int calls, stops, starts;
 public void discoverServices(String t,int p,DiscoveryListener l){discovery=l;starts++;}
 public void stopServiceDiscovery(DiscoveryListener l){stops++;}
 // minSdk 34：只有带执行器的版本，回调像真机一样经执行器送达（产品代码不再自己 post）
 public void resolveService(NsdServiceInfo s,java.util.concurrent.Executor x,ResolveListener l){calls++;resolve=new ResolveListener(){
  public void onResolveFailed(NsdServiceInfo i,int e){x.execute(()->l.onResolveFailed(i,e));}
  public void onServiceResolved(NsdServiceInfo i){x.execute(()->l.onServiceResolved(i));}};}
}
''',
'org/s2arm/android/BrowserProbe.java': '''package org.s2arm.android;
import android.net.nsd.*; import android.os.Handler; import java.util.*;
public class BrowserProbe {
 static void check(boolean b,String why){if(!b)throw new AssertionError(why);}
 public static void main(String[] args)throws Exception{
 NsdManager m=new NsdManager();Handler h=new Handler();List<LanDiscoverySession.Peer[]> changes=new ArrayList<>();
 LanDiscoveryBrowser b=new LanDiscoveryBrowser(m,h,changes::add);b.start("0123-");h.drain();
 var a=new NsdServiceInfo("0123-a","192.0.2.1");var z=new NsdServiceInfo("0123-z","192.0.2.2");
 m.discovery.onServiceFound(new NsdServiceInfo("9999-other","192.0.2.99"));h.drain();
 check(m.calls==0,"cross-program discovery not filtered");
 m.discovery.onServiceFound(a);m.discovery.onServiceFound(z);m.discovery.onServiceFound(z);h.drain();
 check(m.calls==1,"parallel or duplicate legacy resolution");
 var old=m.resolve;old.onServiceResolved(a);h.drain();check(m.calls==2,"queue not drained after resolve");
 check(changes.size()==1&&changes.get(0)[0].name.equals("0123-a"),"first resolved peer missing");
 m.discovery.onServiceLost(z);m.resolve.onServiceResolved(z);h.drain();
 check(changes.size()==1,"lost service resurrected by late result");
 var oldDiscovery=m.discovery;b.stop();b.start("0123-");h.drain();check(m.stops==1,"old discovery not stopped");
 oldDiscovery.onServiceFound(a);old.onServiceResolved(a);h.drain();check(changes.size()==1,"old generation leaked");
 m.discovery.onServiceFound(a);h.drain();m.resolve.onServiceResolved(new NsdServiceInfo("0123-a","::1"));h.drain();
 check(changes.size()==1,"IPv6 accepted by IPv4 callback");
 m.discovery.onServiceFound(a);h.drain();m.resolve.onServiceResolved(a);h.drain();check(changes.size()==2,"resolve retry lost");
 b.stop();h.drain();
 b.start("0123-");h.drain();m.discovery.onServiceFound(a);h.drain();
 var pending=m.resolve;int before=m.calls;b.stop();b.start("0123-");h.drain();
 m.discovery.onServiceFound(z);h.drain();check(m.calls==before,"restart overlapped unresolved legacy request");
 pending.onServiceResolved(a);h.drain();check(m.calls==before+1,"old completion did not release new queue");
 pending.onServiceResolved(a);m.discovery.onServiceFound(a);h.drain();check(m.calls==before+1,"duplicate old completion released new resolve");
 m.resolve.onServiceResolved(z);h.drain();b.stop();h.drain();
 b.start("0123-");h.drain();m.discovery.onStartDiscoveryFailed("",3);h.drain();
 int started=m.starts;b.start("0123-");h.drain();check(m.starts==started+1,"failed discovery cannot retry");
 b.stop();h.drain();
 NsdManager cleanup=new NsdManager();LanDiscoveryBrowser cb=new LanDiscoveryBrowser(cleanup,h,peers -> {});
 cb.start("0123-");h.drain();var retiring=cleanup.discovery;cb.stop();h.drain();
 retiring.onStopDiscoveryFailed("",3);h.drain();cb.stop();h.drain();check(cleanup.stops==2,"failed cleanup listener lost");
 retiring.onDiscoveryStopped("");h.drain();cb.stop();h.drain();check(cleanup.stops==2,"successful cleanup retried");
 System.out.println("PASS: real adapter callback queue, filters, stale generation, loss, IPv4 retry");
 }}'''
}
with tempfile.TemporaryDirectory(prefix='s2a-lan-nsd-') as tmp:
    out = pathlib.Path(tmp)
    paths = []
    for name, body in STUBS.items():
        p = out / name
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(body)
        paths.append(str(p))
    source = ROOT / 'app/src/main/java/org/s2arm/android'
    subprocess.run([str(JAVAC), '-Xlint:all', '-Werror', '-d', str(out), *paths,
                    str(source / 'LanDiscoverySession.java'), str(source / 'LanDiscoveryBrowser.java')], check=True)
    subprocess.run([str(JAVA), '-cp', str(out), 'org.s2arm.android.BrowserProbe'], check=True, timeout=15)
