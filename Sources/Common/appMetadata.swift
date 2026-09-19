public let stableWinMuxAppId: String = "com.zimengxiong.winmux"
#if DEBUG
    public let winMuxAppId: String = "com.zimengxiong.winmux.debug"
    public let winMuxAppName: String = "WinMux-Debug"
    public let winMuxAppDisplayName: String = "WinMux Dev"
#else
    public let winMuxAppId: String = stableWinMuxAppId
    public let winMuxAppName: String = "WinMux"
    public let winMuxAppDisplayName: String = winMuxAppName
#endif
