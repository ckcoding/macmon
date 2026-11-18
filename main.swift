import Foundation

// MARK: - main

let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else {
    printUsage()
    exit(0)
}

switch cmd {
case "run":
    cmdRun(args.dropFirst())
case "status":
    cmdStatus(args.dropFirst())
case "top":
    cmdTop(args.dropFirst())
case "install":
    cmdInstall(args.dropFirst())
case "uninstall":
    let uid = getuid()
    sh("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"])
    try? FileManager.default.removeItem(at: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/\(label).plist"))
    out("✅ 已卸载 LaunchAgent")
case "test-notify":
    sendNotification("✅ macmon 通知通道正常", "这是一条测试通知，之后 CPU/内存/swap 异常都会这样提醒你。", sound: "Glass")
    out("已发送测试通知")
case "help", "-h", "--help":
    printUsage()
case "--version", "version":
    out("macmon \(VERSION)")
default:
    FileHandle.standardError.write(Data("未知命令：\(cmd)\n\n".utf8))
    printUsage()
    exit(2)
}
