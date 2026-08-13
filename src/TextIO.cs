using System.Text;

namespace SafeRG;

/// <summary>文本解码：BOM 探测 + 严格 UTF-8 + GB18030/GBK 兜底，保证中文不乱码。</summary>
public static class TextIO
{
    public static string DecodeText(byte[] bytes)
    {
        if (bytes.Length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF)
            return Encoding.UTF8.GetString(bytes, 3, bytes.Length - 3);            // UTF-8 BOM
        if (bytes.Length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE)
            return Encoding.Unicode.GetString(bytes, 2, bytes.Length - 2);        // UTF-16 LE
        if (bytes.Length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF)
            return Encoding.BigEndianUnicode.GetString(bytes, 2, bytes.Length - 2); // UTF-16 BE
        try { return new UTF8Encoding(false, true).GetString(bytes); }            // 严格 UTF-8（无 BOM）
        catch (DecoderFallbackException) { /* 不是合法 UTF-8，尝试旧中文编码 */ }
        Encoding? gb = TryGetGb();
        if (gb != null)
        {
            try { return gb.GetString(bytes); } catch { }
        }
        return new UTF8Encoding(false, false).GetString(bytes);                   // 宽松 UTF-8 兜底
    }

    public static string ReadFileText(string path) => DecodeText(File.ReadAllBytes(path));

    /// <summary>严格 UTF-8 校验（用于 legacy 补搜时过滤假匹配：GBK 解码命中但文件本身是合法 UTF-8 的情况）。</summary>
    public static bool IsStrictUtf8(byte[] bytes)
    {
        try { _ = new UTF8Encoding(false, true).GetString(bytes); return true; }
        catch (DecoderFallbackException) { return false; }
    }

    /// <summary>GB18030（优先）→ GBK：兼容旧的中文（GBK）源文件。</summary>
    static Encoding? TryGetGb()
    {
        try { return Encoding.GetEncoding(54936); } catch { }
        try { return Encoding.GetEncoding(936); } catch { }
        return null;
    }
}
