// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// D-97FT（Windows 0.6.9，界面停在「准备这台电脑 / 正在检查」）两处，无头窗口按真实页面跑，期望手写：
//   ① 游戏库里一款的封面是坏图（空文件 / 不是图片）：整页照常画出、这一格是占位图，另一款好封面照常显示；
//      原先 Skia 解出空图、Avalonia 构造位图时抛 NullReferenceException，RenderLibrary 中断，出错后的重画又炸。
//   ② 设置页输入框还没画出来（新窗口直接把 page 设成 settings）就起环境检查：路径不变空、检查不抛「路径为空」。
// 调用方核退出码 0 和末行「✓」。
using System.Reflection;
using Avalonia.Controls;
using Avalonia.Headless;
using Avalonia.Media.Imaging;
using Avalonia.Threading;
using Avalonia.VisualTree;
using S2Arm.Launcher;
using S2Arm.Launcher.Protocol;

static class CoverProbe
{
    const BindingFlags F = BindingFlags.NonPublic | BindingFlags.Instance;

    public static int Run(string outDir)
    {
        Directory.CreateDirectory(outDir);
        var fails = new List<string>();
        Exception? error = null;
        DispatcherUnhandledExceptionEventHandler trap = (_, e) => { error ??= e.Exception; e.Handled = true; };
        Dispatcher.UIThread.UnhandledException += trap;
        var lib = Path.Combine(outDir, "library");
        try
        {
            // ① 坏封面：一款空文件、一款随机字节；另一款是真 PNG
            LibraryGame Game(string id, string name, byte[] cover)
            {
                var folder = Path.Combine(lib, "games", name); Directory.CreateDirectory(folder);
                var file = Path.Combine(folder, "cover.jpg"); File.WriteAllBytes(file, cover);
                return new(id, name, "v1.0.0", file, false, [], Location: new GameLocation("ok", folder, folder, "C:", true));
            }
            var good = new MemoryStream();
            new WriteableBitmap(new Avalonia.PixelSize(8, 8), new Avalonia.Vector(96, 96), Avalonia.Platform.PixelFormat.Bgra8888).Save(good);
            var empty = Game("0100F00A00000000", "empty-cover", []);
            var junk = Game("0100F00B00000000", "junk-cover", Enumerable.Range(0, 4096).Select(i => (byte)(i * 37)).ToArray());
            var fine = Game("0100F00C00000000", "good-cover", good.ToArray());
            var w = new EnvironmentWindow { Width = 1180, Height = 900 };
            w.Show(); Settle(w);
            Set(w, "catalog", new LibraryCatalog([empty, junk, fine], true, "密钥已就绪"));
            Set(w, "connectedFolder", lib); Set(w, "libraryId", "probe-lib"); Set(w, "librarySummary", "library.completed");
            Set(w, "updateHintsFor", "probe-lib");
            foreach (var g in new[] { empty, junk, fine })
            {
                error = null;
                Set(w, "selectedGame", g.Id); Navigate(w, "library"); Settle(w); Call(w, "Render"); Settle(w);
                Check(fails, $"坏封面·选中 {g.Name}：整页画完、没有异常（{error?.GetType().Name}: {error?.Message}）", error is null);
            }
            var images = w.GetVisualDescendants().OfType<Image>().Count(i => i.Source is Bitmap b && b.PixelSize.Width == 240);
            Check(fails, $"坏封面：好封面那款照常显示（找到 {images} 张）", images > 0);
            var bmp = w.CaptureRenderedFrame();
            if (bmp is not null) { using var s = File.Create(Path.Combine(outDir, "bad_cover.png")); bmp.Save(s); }
            w.Close(); Settle(w);

            // ② 设置页输入框没画出来就起检查
            error = null;
            var v = new EnvironmentWindow { Width = 1180, Height = 900 };
            v.Show(); Settle(v);
            var before = (LauncherPaths)Get(v, "paths")!;
            Set(v, "engine", new TextBox()); Set(v, "runtime", new TextBox()); Set(v, "shell", new TextBox());   // 同字段初值：还没画过设置页
            Set(v, "page", "settings");
            var task = (Task)v.GetType().GetMethod("CheckAsync", F)!.Invoke(v, null)!;
            var until = DateTime.UtcNow.AddSeconds(20);
            while (!task.IsCompleted && DateTime.UtcNow < until) { Dispatcher.UIThread.RunJobs(); Thread.Sleep(20); }
            var after = (LauncherPaths)Get(v, "paths")!;
            Check(fails, $"没画出的设置框：路径不变空（之前 {before.Engine}，之后「{after.Engine}」）", after == before);
            Check(fails, $"没画出的设置框：环境检查不抛异常（{task.Exception?.InnerException?.GetType().Name}: {task.Exception?.InnerException?.Message}）", !task.IsFaulted);
            v.Close(); Settle(v);
        }
        catch (Exception e) { fails.Add($"探针自身出错：{e.GetType().Name}: {e.Message}\n{e.StackTrace}"); }
        finally { Dispatcher.UIThread.UnhandledException -= trap; }
        foreach (var f in fails) Console.WriteLine("不通 " + f);
        Console.WriteLine($"{(fails.Count == 0 ? "✓" : "✗")} 坏封面与没画出的设置框：不通 {fails.Count}");
        return fails.Count == 0 ? 0 : 1;
    }

    static void Check(List<string> fails, string what, bool ok) { Console.WriteLine((ok ? "通 " : "不通 ") + what); if (!ok) fails.Add(what); }
    static void Navigate(EnvironmentWindow w, string page) => w.GetType().GetMethod("Navigate", F)!.Invoke(w, [page]);
    static void Call(EnvironmentWindow w, string name) => w.GetType().GetMethod(name, F, [])!.Invoke(w, null);
    static void Settle(Window w) { Dispatcher.UIThread.RunJobs(); w.UpdateLayout(); Dispatcher.UIThread.RunJobs(); }
    static object? Get(object obj, string field) => obj.GetType().GetField(field, F)?.GetValue(obj) ?? obj.GetType().GetProperty(field, F)?.GetValue(obj);
    static void Set(object obj, string field, object? value)
    {
        var fi = obj.GetType().GetField(field, F);
        if (fi is not null) { fi.SetValue(obj, value); return; }
        (obj.GetType().GetProperty(field, F | BindingFlags.Public) ?? throw new MissingMemberException(field)).SetValue(obj, value);
    }
}
