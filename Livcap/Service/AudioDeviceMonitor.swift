import Foundation
import OSLog
import CoreAudio
import AudioToolbox

final class AudioDeviceMonitor {
    typealias DeviceChangeCallback = (_ defaultInputName: String?) -> Void
    typealias DeviceListChangeCallback = () -> Void

    private let logger = Logger(subsystem: "com.livcap.audio", category: "AudioDeviceMonitor")
    private var deviceChangeCallback: DeviceChangeCallback?
    private var deviceListChangeCallback: DeviceListChangeCallback?

    // Debounce to avoid multiple fires per change
    private var pendingNotify: DispatchWorkItem?
    private let debounceInterval: TimeInterval = 0.1

    init() {
        setupCoreAudioListeners()
        logger.info("AudioDeviceMonitor initialized")
    }

    deinit {
        teardownCoreAudioListeners()
    }

    func onDeviceChanged(_ callback: @escaping DeviceChangeCallback) {
        self.deviceChangeCallback = callback
    }

    func onDeviceListChanged(_ callback: @escaping DeviceListChangeCallback) {
        self.deviceListChangeCallback = callback
    }

    // MARK: - Notify helper
    private func emitChange() {
        // Debounce
        pendingNotify?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let name = self.currentDefaultInputName()
            self.logger.info("🔄 Audio input device changed to: \(name ?? "unknown")")
            self.deviceChangeCallback?(name)
        }
        pendingNotify = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    // MARK: - Core Audio (macOS)
    private var propertyAddresses: [AudioObjectPropertyAddress] = []
    private var listenersInstalled = false

    private func setupCoreAudioListeners() {
        // We care about: default input device + device list changes
        let defaultInputAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let deviceListAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        propertyAddresses = [defaultInputAddr, deviceListAddr]

        let systemObjectID = AudioObjectID(kAudioObjectSystemObject)

        var defaultAddr = defaultInputAddr
        AudioObjectAddPropertyListenerBlock(systemObjectID, &defaultAddr, DispatchQueue.main) { [weak self] _, _ in
            self?.emitChange()
        }

        var listAddr = deviceListAddr
        AudioObjectAddPropertyListenerBlock(systemObjectID, &listAddr, DispatchQueue.main) { [weak self] _, _ in
            self?.deviceListChangeCallback?()
        }

        listenersInstalled = true
    }

    private func teardownCoreAudioListeners() {
        guard listenersInstalled else { return }
        let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
        for var addr in propertyAddresses {
            let status = AudioObjectRemovePropertyListenerBlock(systemObjectID, &addr, DispatchQueue.main, { _, _ in })
            if status != noErr {
                logger.error("Failed to remove CoreAudio listener: \(status)")
            }
        }
        listenersInstalled = false
    }

    // MARK: - Device Enumeration

    func availableInputDevices() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let systemObj = AudioObjectID(kAudioObjectSystemObject)

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObj, &address, 0, nil, &dataSize) == noErr else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var deviceIDs = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(systemObj, &address, 0, nil, &dataSize, &deviceIDs) == noErr else { return [] }

        var result: [AudioInputDevice] = []
        for deviceID in deviceIDs {
            // Check for at least one input channel
            var inputAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var inputSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(deviceID, &inputAddr, 0, nil, &inputSize) == noErr,
                  inputSize >= MemoryLayout<AudioBufferList>.size else { continue }

            let rawPtr = UnsafeMutableRawPointer.allocate(byteCount: Int(inputSize),
                                                          alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { rawPtr.deallocate() }
            guard AudioObjectGetPropertyData(deviceID, &inputAddr, 0, nil, &inputSize, rawPtr) == noErr else { continue }
            let bufferList = rawPtr.assumingMemoryBound(to: AudioBufferList.self)
            guard bufferList.pointee.mNumberBuffers > 0 else { continue }

            // Get device name
            var nameAddr = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var cfName: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString?>.size)
            guard AudioObjectGetPropertyData(deviceID, &nameAddr, 0, nil, &nameSize, &cfName) == noErr else { continue }

            result.append(AudioInputDevice(id: deviceID, name: cfName as String))
        }
        return result
    }

    private func currentDefaultInputID() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(0)
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        )
        return (status == noErr && deviceID != 0) ? deviceID : nil
    }

    private func currentDefaultInputName() -> String? {
        guard let dev = currentDefaultInputID() else { return nil }
        var name: CFString = "" as CFString
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        let status = AudioObjectGetPropertyData(dev, &address, 0, nil, &dataSize, &name)
        if status == noErr { return name as String }
        return nil
    }
}
