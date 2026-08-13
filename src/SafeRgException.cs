namespace SafeRG;

/// <summary>SafeRG 自定义错误：统一输出 [SafeRG] 前缀并返回 exit code 2。</summary>
public sealed class SafeRgException : Exception
{
    public SafeRgException(string message) : base(message) { }
}
