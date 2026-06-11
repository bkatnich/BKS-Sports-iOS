#!/usr/bin/env swift
// driver.swift — BKS Baseball iOS Simulator driver
// Usage: swift .claude/skills/run-bks-baseball/driver.swift <command>
// Commands: boot, build, install, launch, screenshot [path], tap <x> <y>, ss [path], board

import CoreGraphics
import Foundation
import AppKit

// MARK: - Config

let DEVICE_ID = "696C988E-E778-474C-BE5B-023EEFF8B45F"
let BUNDLE_ID = "com.blackkatt.bksbaseball"
let DEBUG_TOKEN = "2CF93C60-C363-4A79-9BA7-130EEBD5E3BF"
let DERIVED_DATA = "/tmp/bks-dd"
let PROJECT = "App/BKSBaseball.xcodeproj"
let SCHEME = "BKSBaseball"

// Simulator window geometry (re-detected each session via getSimWindow())
// The window is frameless (chrome=0): device fills window entirely
// Device: 393pt × 852pt logical; window size varies with zoom level
// Tap mapping: screenX = winX + (devX/393) * winW
//              screenY = winY + (devY/852) * winH

struct SimWindow {
    let x, y, w, h: CGFloat
}

func getSimWindow() -> SimWindow? {
    guard let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
        return nil
    }
    for win in windows {
        let owner = win["kCGWindowOwnerName"] as? String ?? ""
        guard owner.contains("Simulator") else { continue }
        let bounds = win["kCGWindowBounds"] as? [String: CGFloat] ?? [:]
        let w = bounds["Width"] ?? 0
        let h = bounds["Height"] ?? 0
        if w > 300 && h > 600 {
            return SimWindow(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, w: w, h: h)
        }
    }
    return nil
}

func tap(devX: CGFloat, devY: CGFloat, win: SimWindow, label: String = "") {
    let tapX = win.x + (devX / 393) * win.w
    let tapY = win.y + (devY / 852) * win.h
    let pos = CGPoint(x: tapX, y: tapY)
    let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: pos, mouseButton: .left)!
    let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: pos, mouseButton: .left)!
    down.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.1)
    up.post(tap: .cghidEventTap)
    if !label.isEmpty { print("tap \(label) @ device(\(Int(devX)),\(Int(devY)))") }
}

func tapAbsolute(x: CGFloat, y: CGFloat, label: String = "") {
    let pos = CGPoint(x: x, y: y)
    let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: pos, mouseButton: .left)!
    let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: pos, mouseButton: .left)!
    down.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.1)
    up.post(tap: .cghidEventTap)
    if !label.isEmpty { print("tap \(label) @ screen(\(Int(x)),\(Int(y)))") }
}

@discardableResult
func shell(_ args: String..., env: [String: String] = [:]) -> Int32 {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    proc.arguments = args
    if !env.isEmpty {
        var combined = ProcessInfo.processInfo.environment
        for (k, v) in env { combined[k] = v }
        proc.environment = combined
    }
    try? proc.run()
    proc.waitUntilExit()
    return proc.terminationStatus
}

func screenshot(path: String) {
    shell("xcrun", "simctl", "io", DEVICE_ID, "screenshot", path)
    print("screenshot → \(path)")
}

// MARK: - Commands

let args = CommandLine.arguments
let cmd = args.count > 1 ? args[1] : "help"

switch cmd {

case "boot":
    print("Booting \(DEVICE_ID)...")
    shell("xcrun", "simctl", "boot", DEVICE_ID)
    Thread.sleep(forTimeInterval: 3)
    print("Booted.")

case "build":
    print("Building \(SCHEME)...")
    let status = shell(
        "xcodebuild",
        "-project", PROJECT,
        "-scheme", SCHEME,
        "-sdk", "iphonesimulator",
        "-destination", "platform=iOS Simulator,id=\(DEVICE_ID)",
        "-derivedDataPath", DERIVED_DATA,
        "build"
    )
    print(status == 0 ? "Build succeeded." : "Build FAILED (\(status))")
    exit(status)

case "install":
    let appPath = "\(DERIVED_DATA)/Build/Products/Debug-iphonesimulator/BKSBaseball.app"
    print("Installing from \(appPath)...")
    let status = shell("xcrun", "simctl", "install", DEVICE_ID, appPath)
    print(status == 0 ? "Installed." : "Install FAILED (\(status))")
    exit(status)

case "launch":
    print("Launching with App Check debug token...")
    let status = shell(
        "xcrun", "simctl", "launch", DEVICE_ID, BUNDLE_ID,
        env: ["SIMCTL_CHILD_FIRAAppCheckDebugToken": DEBUG_TOKEN]
    )
    Thread.sleep(forTimeInterval: 6)
    print(status == 0 ? "Launched." : "Launch returned \(status) (may still be running)")

case "terminate":
    shell("xcrun", "simctl", "terminate", DEVICE_ID, BUNDLE_ID)
    print("Terminated.")

case "screenshot", "ss":
    let path = args.count > 2 ? args[2] : "/tmp/bks-ss.png"
    screenshot(path: path)

case "tap":
    guard args.count >= 4,
          let x = Double(args[2]),
          let y = Double(args[3]) else {
        print("Usage: driver tap <screen-x> <screen-y>")
        exit(1)
    }
    tapAbsolute(x: CGFloat(x), y: CGFloat(y), label: "manual")

case "tap-dev":
    // Tap using device coordinates (0-393 x, 0-852 y)
    guard args.count >= 4,
          let devX = Double(args[2]),
          let devY = Double(args[3]),
          let win = getSimWindow() else {
        print("Usage: driver tap-dev <device-x> <device-y>")
        exit(1)
    }
    tap(devX: CGFloat(devX), devY: CGFloat(devY), win: win, label: "dev-coords")

case "window":
    if let w = getSimWindow() {
        print("Simulator window: x=\(w.x) y=\(w.y) w=\(w.w) h=\(w.h)")
    } else {
        print("Simulator window not found.")
    }

case "board":
    // Full flow: launch → dismiss any dialogs → reach board
    // Requires app already installed and user already signed in (keychain has credential)
    guard let win = getSimWindow() else {
        print("ERROR: Simulator window not found. Run: driver boot")
        exit(1)
    }
    print("Launching app...")
    shell("xcrun", "simctl", "terminate", DEVICE_ID, BUNDLE_ID)
    Thread.sleep(forTimeInterval: 1)
    shell("xcrun", "simctl", "launch", DEVICE_ID, BUNDLE_ID,
          env: ["SIMCTL_CHILD_FIRAAppCheckDebugToken": DEBUG_TOKEN])
    Thread.sleep(forTimeInterval: 6)

    // Dismiss privacy notice if present (first launch only)
    screenshot(path: "/tmp/bks-board-0.png")
    print("Check /tmp/bks-board-0.png — if privacy notice shown, dismissing...")
    // Tap "Continue" button area (device y≈600)
    tap(devX: 196, devY: 600, win: win, label: "dismiss-privacy")
    Thread.sleep(forTimeInterval: 2)
    screenshot(path: "/tmp/bks-board-1.png")
    print("Board reached (or sign-in shown). See /tmp/bks-board-1.png")

default:
    print("""
BKS Baseball driver — commands:
  boot           Boot the simulator
  build          Build the app
  install        Install built app to simulator
  launch         Launch app with Firebase App Check token
  terminate      Terminate running app
  screenshot [path]  Take screenshot (default: /tmp/bks-ss.png)
  ss [path]          Alias for screenshot
  tap <sx> <sy>      Tap at absolute screen coordinates
  tap-dev <dx> <dy>  Tap at device logical coordinates (0-393, 0-852)
  window         Print current simulator window bounds
  board          Launch app and navigate to board (auth required)
""")
}
