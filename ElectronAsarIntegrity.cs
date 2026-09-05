using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Web.Script.Serialization;
using System.Reflection;

internal static class ElectronAsarIntegrity
{
    private const string ResourceType = "Integrity";
    private const string ResourceName = "ElectronAsar";
    private const string AppAsarPath = "resources\\app.asar";
    private const uint LoadLibraryAsDataFile = 0x00000002;
    private const uint LoadLibraryAsImageResource = 0x00000020;

    private delegate bool EnumResourceLanguageCallback(
        IntPtr module,
        IntPtr type,
        IntPtr name,
        ushort language,
        IntPtr parameter);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr LoadLibraryEx(string fileName, IntPtr file, uint flags);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool FreeLibrary(IntPtr module);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool EnumResourceLanguages(
        IntPtr module,
        string type,
        string name,
        EnumResourceLanguageCallback callback,
        IntPtr parameter);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr FindResourceEx(
        IntPtr module,
        string type,
        string name,
        ushort language);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr LoadResource(IntPtr module, IntPtr resource);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr LockResource(IntPtr resourceData);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint SizeofResource(IntPtr module, IntPtr resource);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr BeginUpdateResource(
        string fileName,
        [MarshalAs(UnmanagedType.Bool)] bool deleteExistingResources);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UpdateResource(
        IntPtr update,
        string type,
        string name,
        ushort language,
        byte[] data,
        uint size);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool EndUpdateResource(
        IntPtr update,
        [MarshalAs(UnmanagedType.Bool)] bool discard);

    private sealed class ResourceDocument
    {
        internal ushort Language;
        internal string Text;
    }

    private static readonly JavaScriptSerializer Json = CreateJsonSerializer();

    private static JavaScriptSerializer CreateJsonSerializer()
    {
        JavaScriptSerializer serializer = new JavaScriptSerializer();
        serializer.MaxJsonLength = int.MaxValue;
        return serializer;
    }

    private static int Main(string[] args)
    {
        try
        {
            if (args.Length == 1 && args[0] == "--self-test")
            {
                SelfTest();
                Console.WriteLine("{\"ok\":true,\"selfTest\":true}");
                return 0;
            }

            if (args.Length != 3 || (args[0] != "sync" && args[0] != "verify"))
            {
                Console.Error.WriteLine(
                    "Usage: ElectronAsarIntegrity.exe --self-test | <sync|verify> <ChatGPT.exe> <app.asar>");
                return 2;
            }

            string executablePath = Path.GetFullPath(args[1]);
            string asarPath = Path.GetFullPath(args[2]);
            if (!File.Exists(executablePath) || !File.Exists(asarPath))
                throw new FileNotFoundException("The executable or ASAR file does not exist.");

            string headerHash = HashAsarHeader(asarPath);
            bool changed = false;
            if (args[0] == "sync")
                changed = Synchronize(executablePath, headerHash);

            ResourceDocument[] documents = ReadResourceDocuments(executablePath);
            VerifyDocuments(documents, headerHash);
            Console.WriteLine(Json.Serialize(new Dictionary<string, object>
            {
                { "ok", true },
                { "mode", args[0] },
                { "changed", changed },
                { "headerSha256", headerHash },
                { "languages", Array.ConvertAll(documents, item => (int)item.Language) }
            }));
            return 0;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine(error.GetType().Name + ": " + error.Message);
            return 1;
        }
    }

    private static string HashAsarHeader(string path)
    {
        using (FileStream stream = File.OpenRead(path))
        using (BinaryReader reader = new BinaryReader(stream, Encoding.UTF8, true))
        {
            if (stream.Length < 16 || reader.ReadUInt32() != 4)
                throw new InvalidDataException("Unsupported ASAR size pickle.");

            uint headerSize = reader.ReadUInt32();
            uint headerPayloadSize = reader.ReadUInt32();
            uint jsonSize = reader.ReadUInt32();
            if (headerSize < 8 || headerPayloadSize != headerSize - 4 ||
                jsonSize < 1 || jsonSize > headerSize - 8 || 8L + headerSize > stream.Length)
                throw new InvalidDataException("Invalid ASAR header lengths.");

            byte[] headerJson = reader.ReadBytes(checked((int)jsonSize));
            if (headerJson.Length != jsonSize)
                throw new EndOfStreamException("Short ASAR header read.");

            Json.DeserializeObject(Encoding.UTF8.GetString(headerJson));
            using (SHA256 sha256 = SHA256.Create())
                return ToHex(sha256.ComputeHash(headerJson));
        }
    }

    private static bool Synchronize(string executablePath, string expectedHash)
    {
        ResourceDocument[] documents = ReadResourceDocuments(executablePath);
        bool changed = false;
        foreach (ResourceDocument document in documents)
        {
            bool documentChanged;
            document.Text = RewriteDocument(document.Text, expectedHash, out documentChanged);
            changed |= documentChanged;
        }
        if (!changed)
            return false;

        WriteResourceDocuments(executablePath, documents);
        return true;
    }

    private static void WriteResourceDocuments(string executablePath, ResourceDocument[] documents)
    {
        IntPtr update = BeginUpdateResource(executablePath, false);
        if (update == IntPtr.Zero)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "BeginUpdateResource failed.");

        bool committed = false;
        try
        {
            foreach (ResourceDocument document in documents)
            {
                byte[] value = Encoding.UTF8.GetBytes(document.Text);
                if (!UpdateResource(
                    update,
                    ResourceType,
                    ResourceName,
                    document.Language,
                    value,
                    checked((uint)value.Length)))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "UpdateResource failed.");
            }
            if (!EndUpdateResource(update, false))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "EndUpdateResource failed.");
            committed = true;
        }
        finally
        {
            if (!committed)
                EndUpdateResource(update, true);
        }
    }

    private static ResourceDocument[] ReadResourceDocuments(string executablePath)
    {
        IntPtr module = LoadLibraryEx(
            executablePath,
            IntPtr.Zero,
            LoadLibraryAsDataFile | LoadLibraryAsImageResource);
        if (module == IntPtr.Zero)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "LoadLibraryEx failed.");

        try
        {
            List<ushort> languages = new List<ushort>();
            EnumResourceLanguageCallback callback = delegate(
                IntPtr ignoredModule,
                IntPtr ignoredType,
                IntPtr ignoredName,
                ushort language,
                IntPtr ignoredParameter)
            {
                languages.Add(language);
                return true;
            };
            if (!EnumResourceLanguages(
                module,
                ResourceType,
                ResourceName,
                callback,
                IntPtr.Zero))
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "The ElectronAsar integrity resource is missing.");
            GC.KeepAlive(callback);

            List<ResourceDocument> result = new List<ResourceDocument>();
            foreach (ushort language in languages)
            {
                IntPtr resource = FindResourceEx(module, ResourceType, ResourceName, language);
                if (resource == IntPtr.Zero)
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "FindResourceEx failed.");
                uint size = SizeofResource(module, resource);
                IntPtr loaded = LoadResource(module, resource);
                IntPtr pointer = LockResource(loaded);
                if (size == 0 || loaded == IntPtr.Zero || pointer == IntPtr.Zero)
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not read the integrity resource.");

                byte[] data = new byte[size];
                Marshal.Copy(pointer, data, 0, data.Length);
                result.Add(new ResourceDocument
                {
                    Language = language,
                    Text = Encoding.UTF8.GetString(data).TrimEnd('\0')
                });
            }
            if (result.Count == 0)
                throw new InvalidDataException("The ElectronAsar integrity resource has no languages.");
            return result.ToArray();
        }
        finally
        {
            FreeLibrary(module);
        }
    }

    private static string RewriteDocument(string text, string expectedHash, out bool changed)
    {
        object[] entries = Json.DeserializeObject(text) as object[];
        if (entries == null)
            throw new InvalidDataException("The ElectronAsar integrity resource is not a JSON array.");

        bool found = false;
        changed = false;
        foreach (object item in entries)
        {
            Dictionary<string, object> entry = item as Dictionary<string, object>;
            if (entry == null || !entry.ContainsKey("file") ||
                !NormalizePath(Convert.ToString(entry["file"])).Equals(
                    AppAsarPath,
                    StringComparison.OrdinalIgnoreCase))
                continue;

            found = true;
            string algorithm = entry.ContainsKey("alg") ? Convert.ToString(entry["alg"]) : "";
            if (!algorithm.Equals("SHA256", StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("The app.asar integrity algorithm is not SHA256.");
            string value = entry.ContainsKey("value") ? Convert.ToString(entry["value"]) : "";
            if (!value.Equals(expectedHash, StringComparison.OrdinalIgnoreCase))
            {
                entry["value"] = expectedHash;
                changed = true;
            }
        }
        if (!found)
            throw new InvalidDataException("The ElectronAsar integrity resource has no resources\\app.asar entry.");
        return changed ? Json.Serialize(entries) : text;
    }

    private static void VerifyDocuments(ResourceDocument[] documents, string expectedHash)
    {
        foreach (ResourceDocument document in documents)
        {
            bool changed;
            RewriteDocument(document.Text, expectedHash, out changed);
            if (changed)
                throw new InvalidDataException(
                    "The embedded app.asar header hash does not match for language " + document.Language + ".");
        }
    }

    private static string NormalizePath(string value)
    {
        return (value ?? "").Replace('/', '\\');
    }

    private static string ToHex(byte[] value)
    {
        StringBuilder result = new StringBuilder(value.Length * 2);
        foreach (byte item in value)
            result.Append(item.ToString("x2"));
        return result.ToString();
    }

    private static void SelfTest()
    {
        string id = Guid.NewGuid().ToString("N");
        string path = Path.Combine(Path.GetTempPath(), "electron-asar-integrity-" + id + ".asar");
        string executablePath = Path.Combine(Path.GetTempPath(), "electron-asar-integrity-" + id + ".exe");
        byte[] json = Encoding.UTF8.GetBytes("{\"files\":{}}");
        uint headerSize = checked((uint)((8 + json.Length + 3) & ~3));
        try
        {
            using (FileStream stream = File.Create(path))
            using (BinaryWriter writer = new BinaryWriter(stream, Encoding.UTF8, true))
            {
                writer.Write((uint)4);
                writer.Write(headerSize);
                writer.Write(headerSize - 4);
                writer.Write((uint)json.Length);
                writer.Write(json);
                writer.Write(new byte[headerSize - 8 - json.Length]);
            }
            string expected;
            using (SHA256 sha256 = SHA256.Create())
                expected = ToHex(sha256.ComputeHash(json));
            if (!HashAsarHeader(path).Equals(expected, StringComparison.Ordinal))
                throw new InvalidDataException("ASAR header hash self-test failed.");

            File.Copy(Assembly.GetExecutingAssembly().Location, executablePath);
            WriteResourceDocuments(executablePath, new[]
            {
                new ResourceDocument
                {
                    Language = 1033,
                    Text = "[{\"file\":\"resources\\\\app.asar\",\"alg\":\"SHA256\",\"value\":\"" +
                        new string('0', 64) + "\"}]"
                }
            });
            if (!Synchronize(executablePath, expected))
                throw new InvalidDataException("Resource synchronization self-test made no change.");
            VerifyDocuments(ReadResourceDocuments(executablePath), expected);
            if (Synchronize(executablePath, expected))
                throw new InvalidDataException("Resource synchronization self-test was not idempotent.");
        }
        finally
        {
            if (File.Exists(path))
                File.Delete(path);
            if (File.Exists(executablePath))
                File.Delete(executablePath);
        }
    }
}
