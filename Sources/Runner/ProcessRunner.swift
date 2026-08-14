import Foundation

enum ProcessRunner {
    /// 로그인 셸 PATH 를 흉내내 실행 파일을 찾는다. GUI 앱은 셸 PATH 를 물려받지 않는다.
    static func which(_ name: String) -> String? {
        let fm = FileManager.default
        var dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        if let envPath = ProcessInfo.processInfo.environment["PATH"] {
            dirs = envPath.split(separator: ":").map(String.init) + dirs
        }
        let home = fm.homeDirectoryForCurrentUser.path
        dirs += ["\(home)/.local/bin", "\(home)/.bun/bin", "\(home)/.nvm/versions"]
        for d in dirs {
            let p = (d as NSString).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// GUI 프로세스에 부족한 PATH·HOME 을 보강한 환경변수.
    static func enrichedEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
                     "/usr/sbin", "/sbin", "\(home)/.local/bin", "\(home)/.bun/bin"]
        var parts = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        for e in extra where !parts.contains(e) { parts.append(e) }
        env["PATH"] = parts.joined(separator: ":")
        env["HOME"] = home
        // 앱에서 실행한 세션임을 스킬·훅 쪽에서 구분할 수 있게 표시한다.
        env["SKILLDOCK"] = "1"
        return env
    }

    struct Result {
        var exitCode: Int32
        var stdout: String
        var stderr: String
    }

    /// 동기 실행. 백그라운드 큐에서만 호출한다.
    static func run(executable: String,
                    arguments: [String],
                    workingDirectory: String? = nil,
                    timeout: TimeInterval = 300) -> Result {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        proc.environment = enrichedEnvironment()
        if let wd = workingDirectory {
            proc.currentDirectoryURL = URL(fileURLWithPath: wd)
        }
        let outPipe = Pipe(), errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        proc.standardInput = FileHandle.nullDevice

        do { try proc.run() } catch {
            return Result(exitCode: -1, stdout: "", stderr: error.localizedDescription)
        }

        let outData = DispatchQueue(label: "sd.out")
        var outBuf = Data(), errBuf = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            let d = outPipe.fileHandleForReading.readDataToEndOfFile()
            outData.sync { outBuf = d }
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            let d = errPipe.fileHandleForReading.readDataToEndOfFile()
            outData.sync { errBuf = d }
            group.leave()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while proc.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if proc.isRunning {
            proc.terminate()
            return Result(exitCode: -2, stdout: "", stderr: "시간이 초과되어 중단했습니다.")
        }
        group.wait()
        return Result(exitCode: proc.terminationStatus,
                      stdout: String(data: outBuf, encoding: .utf8) ?? "",
                      stderr: String(data: errBuf, encoding: .utf8) ?? "")
    }
}
