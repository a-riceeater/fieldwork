using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;

// Calls the Swift core through its C ABI the way the WinUI frontend will:
// create show -> add roster -> line -> 16-count set -> move -> encode ->
// reopen -> evaluate -> error paths. Exits non-zero on any mismatch.

static class Native
{
    const string Lib = "FieldworkCore";

    [DllImport(Lib)] public static extern uint fw_abi_version();
    [DllImport(Lib)] public static extern int fw_session_create(byte[] title, long length, out ulong handle);
    [DllImport(Lib)] public static extern int fw_session_open(IntPtr document, long length, out ulong handle, out IntPtr data, out long dataLength);
    [DllImport(Lib)] public static extern void fw_session_destroy(ulong handle);
    [DllImport(Lib)] public static extern int fw_dispatch_command(ulong handle, byte[] json, long length, out IntPtr data, out long dataLength);
    [DllImport(Lib)] public static extern int fw_get_snapshot(ulong handle, out IntPtr data, out long dataLength);
    [DllImport(Lib)] public static extern int fw_evaluate_scene(ulong handle, double pulse, out IntPtr data, out long dataLength);
    [DllImport(Lib)] public static extern int fw_encode_document(ulong handle, out IntPtr data, out long dataLength);
    [DllImport(Lib)] public static extern void fw_buffer_free(IntPtr data, long length);

    /// Copies a core-owned buffer into managed memory and releases it with the core's deallocator.
    public static byte[] Take(IntPtr data, long length)
    {
        if (data == IntPtr.Zero) return Array.Empty<byte>();
        var copy = new byte[length];
        Marshal.Copy(data, copy, 0, (int)length);
        fw_buffer_free(data, length);
        return copy;
    }
}

static class Program
{
    static int failures;

    static void Check(bool condition, string what)
    {
        Console.WriteLine($"{(condition ? "PASS" : "FAIL")}  {what}");
        if (!condition) failures++;
    }

    static (int status, JsonElement json) Command(ulong handle, string json)
    {
        var bytes = Encoding.UTF8.GetBytes(json);
        int status = Native.fw_dispatch_command(handle, bytes, bytes.Length, out var data, out var length);
        return (status, JsonDocument.Parse(Native.Take(data, length)).RootElement.Clone());
    }

    static JsonElement Performer(JsonElement scene, string label) =>
        scene.GetProperty("performers").EnumerateArray().First(p => p.GetProperty("label").GetString() == label);

    static int Main()
    {
        Check(Native.fw_abi_version() == 1, "ABI version is 1");

        var title = Encoding.UTF8.GetBytes("Interop Show");
        Check(Native.fw_session_create(title, title.Length, out var handle) == 0, "create session");

        Check(Command(handle, """{"type":"setField","preset":"collegeFootball"}""").status == 0, "choose college football field");
        Check(Command(handle, """{"type":"addSection","name":"Trumpet","prefix":"T","count":16}""").status == 0, "add 16 trumpets");
        Check(Command(handle, """{"type":"addSection","name":"Mellophone","prefix":"M","count":16}""").status == 0, "add 16 mellophones");
        Check(Command(handle, """{"type":"placeLine","set":0,"x0":-18,"y0":0,"x1":18,"y1":0}""").status == 0, "place a line on the preset");
        Check(Command(handle, """{"type":"addSet","after":0,"counts":16}""").status == 0, "add a 16-count set");
        Check(Command(handle, """{"type":"translate","set":1,"dx":0,"dy":9.144}""").status == 0, "move everyone 10 yards back");
        Check(Command(handle, """{"type":"movePerformer","set":1,"performer":"T1","x":-20,"y":12}""").status == 0, "exact coordinate for T1");

        Native.fw_evaluate_scene(handle, 8, out var sceneData, out var sceneLength);
        var mid = JsonDocument.Parse(Native.Take(sceneData, sceneLength)).RootElement;
        var m1 = Performer(mid, "M1");
        Check(Math.Abs(m1.GetProperty("y").GetDouble() - 4.572) < 1e-9, "M1 is halfway (4.572 m) at count 8");

        Check(Native.fw_encode_document(handle, out var docData, out var docLength) == 0, "encode .fieldwork");
        var document = Native.Take(docData, docLength);
        Check(document.Length > 1000 && document[0] == (byte)'P' && document[1] == (byte)'K', $"document is a ZIP container ({document.Length} bytes)");

        var pinned = GCHandle.Alloc(document, GCHandleType.Pinned);
        int openStatus = Native.fw_session_open(pinned.AddrOfPinnedObject(), document.Length, out var reopened, out var openData, out var openLength);
        pinned.Free();
        Native.Take(openData, openLength);
        Check(openStatus == 0, "reopen from bytes");

        Native.fw_get_snapshot(reopened, out var snapData, out var snapLength);
        var snapshot = JsonDocument.Parse(Native.Take(snapData, snapLength)).RootElement;
        Check(snapshot.GetProperty("performers").GetArrayLength() == 32, "reopened show has 32 performers");
        Check(snapshot.GetProperty("sets")[1].GetProperty("count").GetDouble() == 16, "set 2 arrives at count 16");
        Check(snapshot.GetProperty("field").GetProperty("name").GetString() == "College football", "field preserved");

        Native.fw_evaluate_scene(reopened, 16, out var endData, out var endLength);
        var end = JsonDocument.Parse(Native.Take(endData, endLength)).RootElement;
        var t1 = Performer(end, "T1");
        Check(t1.GetProperty("x").GetDouble() == -20 && t1.GetProperty("y").GetDouble() == 12, "T1 arrival preserved exactly after round trip");

        var bad = Command(reopened, """{"type":"movePerformer","set":1,"performer":"Z99","x":0,"y":0}""");
        Check(bad.status == 1 && bad.json.GetProperty("ok").GetBoolean() == false, $"unknown performer is an error: {bad.json.GetProperty("error").GetString()}");
        Native.fw_get_snapshot(reopened, out var afterData, out var afterLength);
        var after = JsonDocument.Parse(Native.Take(afterData, afterLength)).RootElement;
        Check(after.GetProperty("revision").GetInt32() == snapshot.GetProperty("revision").GetInt32(), "failed command left the session unchanged");
        Check(Native.fw_get_snapshot(424242, out var invalidData, out var invalidLength) == 2, "invalid handle reports status 2");
        Native.Take(invalidData, invalidLength);
        var undo = Command(handle, """{"type":"undo"}""");
        Check(undo.status == 0 && undo.json.GetProperty("redo").GetString() == "Move Performer", "undo through the bridge");

        Native.fw_session_destroy(handle);
        Native.fw_session_destroy(reopened);
        Console.WriteLine(failures == 0 ? "All interop checks passed." : $"{failures} interop check(s) failed.");
        return failures == 0 ? 0 : 1;
    }
}
