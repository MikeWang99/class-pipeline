// create_multi_output.swift
//
// Rebuild the pipeline-owned stacked output device from a specific playback
// device and BlackHole. A multi-output device is not adaptive: if it was first
// created while another monitor/headphone was selected, it keeps mirroring that
// stale device forever. Recreating this one at class start prevents the system
// output and BlackHole capture path from drifting apart.
//
// Usage:
//   swift create_multi_output.swift ensure "PhysicsClass Multi-Output" "Mac mini扬声器"

import CoreAudio
import Foundation

let aggregateUID = "physics-class-pipeline-multiout"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(("ERROR: \(message)\n").data(using: .utf8)!)
    exit(1)
}

func check(_ status: OSStatus, _ action: String) {
    if status != noErr {
        fail("\(action) failed (OSStatus \(status))")
    }
}

func deviceList() -> [AudioDeviceID] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    check(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size), "reading audio device list size")
    var devices = [AudioDeviceID](repeating: kAudioObjectUnknown,
                                  count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                     &address, 0, nil, &size, &devices), "reading audio device list")
    return devices
}

func stringProperty(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
          let value else {
        return ""
    }
    return value.takeUnretainedValue() as String
}

func name(of device: AudioDeviceID) -> String {
    stringProperty(device, kAudioDevicePropertyDeviceNameCFString)
}

func uid(of device: AudioDeviceID) -> String {
    stringProperty(device, kAudioDevicePropertyDeviceUID)
}

func device(named wanted: String) -> AudioDeviceID? {
    let exact = deviceList().first { name(of: $0) == wanted }
    return exact ?? deviceList().first { name(of: $0).caseInsensitiveCompare(wanted) == .orderedSame }
}

func updatePersistentDefinition(name aggregateName: String, playbackUID: String, blackHoleUID: String) {
    let fm = FileManager.default
    let byHost = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/ByHost")
    guard let files = try? fm.contentsOfDirectory(at: byHost, includingPropertiesForKeys: nil),
          let path = files.first(where: {
              $0.lastPathComponent.hasPrefix("com.apple.audio.SystemSettings") &&
              $0.pathExtension == "plist"
          }) else {
        return
    }
    guard let data = try? Data(contentsOf: path),
          var plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
        return
    }

    var devices = plist["Audio Device Preferences"] as? [[String: Any]] ?? []
    devices.removeAll { ($0["aggregate-device-uid"] as? String) == aggregateUID }
    devices.append([
        "aggregate-device-uid": aggregateUID,
        "name": aggregateName,
        "main-subdevice": playbackUID,
        "is-stack": 1,
        "is-named": 1,
        "is-hidden": 0,
        "subdevices": [
            ["audio-subdevice-uid": playbackUID, "drift-compensation": 0],
            ["audio-subdevice-uid": blackHoleUID, "drift-compensation": 1],
        ],
    ])
    plist["Audio Device Preferences"] = devices
    guard let output = try? PropertyListSerialization.data(fromPropertyList: plist,
                                                            format: .binary,
                                                            options: 0) else {
        return
    }
    try? output.write(to: path)
}

func ensure(aggregateName: String, playbackName: String) {
    guard let playback = device(named: playbackName) else {
        let choices = deviceList().map(name(of:)).filter { !$0.isEmpty }.joined(separator: "、")
        fail("playback device '\(playbackName)' not found (available: \(choices))")
    }
    guard let blackHole = deviceList().first(where: { name(of: $0).localizedCaseInsensitiveContains("blackhole") }) else {
        fail("BlackHole 2ch is not available")
    }
    guard playback != blackHole else {
        fail("the playback device cannot be BlackHole")
    }

    // The device is owned by this pipeline UID. Removing it is safe and lets
    // the current playback device become the actual main sub-device immediately.
    if let existing = device(named: aggregateName) {
        let status = AudioHardwareDestroyAggregateDevice(existing)
        if status != noErr && status != kAudioHardwareBadObjectError {
            fail("replacing stale multi-output device failed (OSStatus \(status))")
        }
        Thread.sleep(forTimeInterval: 0.25)
    }

    let playbackUID = uid(of: playback)
    let blackHoleUID = uid(of: blackHole)
    updatePersistentDefinition(name: aggregateName, playbackUID: playbackUID, blackHoleUID: blackHoleUID)

    let definition: [String: Any] = [
        kAudioAggregateDeviceUIDKey: aggregateUID,
        kAudioAggregateDeviceNameKey: aggregateName,
        kAudioAggregateDeviceIsPrivateKey: 0,
        kAudioAggregateDeviceIsStackedKey: 1,
        kAudioAggregateDeviceMainSubDeviceKey: playbackUID,
        kAudioAggregateDeviceSubDeviceListKey: [
            [kAudioSubDeviceUIDKey: playbackUID, kAudioSubDeviceDriftCompensationKey: 0],
            [kAudioSubDeviceUIDKey: blackHoleUID, kAudioSubDeviceDriftCompensationKey: 1],
        ],
    ]
    var aggregate = AudioDeviceID(kAudioObjectUnknown)
    check(AudioHardwareCreateAggregateDevice(definition as CFDictionary, &aggregate),
          "creating multi-output device")
    print("multi-output ready: \(aggregateName) = \(playbackName) + \(name(of: blackHole))")
}

guard CommandLine.arguments.count == 4, CommandLine.arguments[1] == "ensure" else {
    fail("usage: create_multi_output.swift ensure <multi-output name> <playback device name>")
}

ensure(aggregateName: CommandLine.arguments[2], playbackName: CommandLine.arguments[3])
