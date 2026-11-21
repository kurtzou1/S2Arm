// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using Ryujinx.Audio.Backends.Common;
using Ryujinx.Audio.Common;
using S2A.Audio.OHAudio;
using System;
using System.Reflection;
using System.Threading;
using System.Threading.Tasks;

internal static class Program
{
    private static T Field<T>(object target, string name) =>
        (T)target.GetType().GetField(name, BindingFlags.NonPublic | BindingFlags.Instance).GetValue(target);

    private static void Require(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private static void PauseFailureStillCloses()
    {
        var driver = new OHAudioHardwareDeviceDriver();
        var session = new OHAudioHardwareDeviceSession(driver, null, SampleFormat.PcmInt16, 48000, 2);
        nint handle = Field<nint>(session, "_sink");
        OHAudioSink.Device device = OHAudioSink.Get(handle);
        session.Start();
        device.PauseError = -5;
        Exception reported = null;
        bool closedAfterFirstDispose = false, feederStopped = false;
        int unregisterAfterFirstDispose = 0;
        try
        {
            Task dispose = Task.Run(() =>
            {
                try { session.Dispose(); }
                catch (Exception error) { reported = error; }
            });
            Require(dispose.Wait(3000), "Dispose did not join its feeder within the test deadline");
            closedAfterFirstDispose = device.CloseCalls == 1 && Field<nint>(session, "_sink") == 0;
            feederStopped = !Field<Thread>(session, "_feeder").IsAlive;
            unregisterAfterFirstDispose = driver.UnregisterCalls;
        }
        finally
        {
            // Old-code negative control must not leave its feeder running in the test process.
            device.PauseError = 0;
            session.Dispose();
        }
        Require(closedAfterFirstDispose, "Pause failure skipped native close on the first Dispose");
        Require(feederStopped, "Pause failure left the feeder alive");
        Require(unregisterAfterFirstDispose == 1, "Pause failure skipped driver unregister");
        Require(reported is InvalidOperationException && reported.ToString().Contains("-5"), "Pause error was swallowed");
        Require(device.CloseCalls == 1 && driver.UnregisterCalls == 1, "Repeated Dispose repeated cleanup");
    }

    private static void PublicationAndAccounting()
    {
        // The two locks are acquired by the test to freeze only the producer's interleaving.
        // Actual QueueBuffer/AudioSampleQueue/FeedLoop/ProcessPlayedSamples remain unchanged.
        for (int iteration = 0; iteration < 16; iteration++)
        {
            var driver = new OHAudioHardwareDeviceDriver();
            var session = new OHAudioHardwareDeviceSession(driver, null, SampleFormat.PcmInt16, 48000, 2);
            nint handle = Field<nint>(session, "_sink");
            var buffer = new AudioBuffer { DataPointer = (ulong)iteration + 1, DataSize = 1920, Data = new byte[1920] };
            Lock writerLock = Field<Lock>(session, "_lock");
            Lock queueLock = Field<Lock>(session, "_queueLock");
            AudioSampleQueue samples = Field<AudioSampleQueue>(session, "_samples");
            using var producerEntered = new ManualResetEventSlim(false);
            Exception producerError = null;
            bool dataPublishedBeforeRecord = false;
            Thread producer = new(() =>
            {
                producerEntered.Set();
                try { session.QueueBuffer(buffer); }
                catch (Exception error) { producerError = error; }
            }) { IsBackground = true };
            try
            {
                session.Start();
                using (writerLock.EnterScope())
                {
                    using (queueLock.EnterScope())
                    {
                        producer.Start();
                        Require(producerEntered.Wait(2000), "Producer did not enter");
                        Require(SpinWait.SpinUntil(() => (producer.ThreadState & ThreadState.WaitSleepJoin) != 0, 2000),
                            "Producer did not reach the forced queue-lock boundary");
                        dataPublishedBeforeRecord = samples.Length != 0 && Field<int>(session, "_queuedCount") == 0;
                    }
                }
                Require(producer.Join(2000), "QueueBuffer did not finish after lock release");
                Require(producerError == null, "QueueBuffer threw: " + producerError);
                Require(!dataPublishedBeforeRecord, "Samples became visible while their accounting record was absent");
                OHAudioSink.s2a_ohaudio_wake(handle);
                Require(SpinWait.SpinUntil(() => session.GetPlayedSampleCount() == 480 && session.WasBufferFullyConsumed(buffer), 2000),
                    "Actual feeder did not return all 480 played frames to the buffer owner");
                Require(driver.GetUpdateRequiredEvent().WaitOne(2000), "Completed buffer did not signal the update event");
                Require(driver.Failures.IsEmpty, "Actual feeder reported a failure");
            }
            finally
            {
                if (producer.IsAlive) producer.Join(2000);
                session.Dispose();
            }
        }
    }

    private static int Main(string[] args)
    {
        string selected = args.Length == 0 ? "all" : args[0];
        int failed = 0;
        (string Name, Action Run)[] cases = [("pause", PauseFailureStillCloses), ("publication", PublicationAndAccounting)];
        foreach (var test in cases)
        {
            if (selected != "all" && selected != test.Name) continue;
            try { test.Run(); Console.WriteLine("PASS " + test.Name); }
            catch (Exception error) { failed++; Console.WriteLine("FAIL " + test.Name + ": " + error.Message); }
        }
        if (selected != "all" && selected != "pause" && selected != "publication") return 2;
        return failed == 0 ? 0 : 1;
    }
}
