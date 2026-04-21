import Foundation
import AVFoundation
import Combine
import os.log

final class AudioCoordinator: ObservableObject {
    
    // MARK: - Published Properties (Direct Boolean Control)
    @Published private(set) var isMicrophoneEnabled: Bool = false
    @Published private(set) var isSystemAudioEnabled: Bool = false

    // MARK: - Private Properties

    // Audio managers
    private let micAudioManager = MicAudioManager()
    private var systemAudioManager: SystemAudioManager?

    // Dynamic consumer management
    private var microphoneConsumerTask: Task<Void, Never>?
    private var systemAudioConsumerTask: Task<Void, Never>?

    // Shared continuation for aggregator stream
    private var streamContinuation: AsyncStream<AudioFrameWithVAD>.Continuation?

    // Propagate device-list changes from micAudioManager to observers of AudioCoordinator
    private var cancellables = Set<AnyCancellable>()

    // Logging
    private let logger = Logger(subsystem: "com.livcap.audio", category: "AudioCoordinator")

    // MARK: - Microphone Device Selection

    var availableInputDevices: [AudioInputDevice] { micAudioManager.availableInputDevices }
    var selectedMicDeviceID: UInt32? { micAudioManager.selectedDeviceID }

    func selectMicrophoneDevice(_ deviceID: UInt32?) {
        micAudioManager.selectDevice(deviceID)
    }

    // MARK: - Source Arbitration (when both sources are enabled)
    private var activeSource: AudioSource?
    private var activeSince: Date?
    private var lastSpeechAtMic: Date?
    private var lastSpeechAtSystem: Date?
    private let minActiveWindow: TimeInterval = 2.0   // minimum time to stick with current source
    private let silenceToSwitch: TimeInterval = 1.0   // if current source silent > 1s, allow switch
    
    // MARK: - Initialization
    
    init() {
        setupSystemAudioComponents()
        // Forward device-list changes so UI updates automatically
        micAudioManager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }
    
    // MARK: - Setup
    
    private func setupSystemAudioComponents() {
        // Initialize system audio components only if supported
        if #available(macOS 14.4, *) {
            systemAudioManager = SystemAudioManager()
        }
    }
    
    // Simplified: Direct control methods replace reactive consumers
    
    // MARK: - Public Control Functions
    
    func enableMicrophone() {
        guard !isMicrophoneEnabled else { 
            logger.info("⚡ Microphone already enabled, skipping")
            return 
        }
        
        logger.info("🎤 Enabling microphone")
        startMicrophone()
    }
    
    func disableMicrophone() {
        guard isMicrophoneEnabled else {
            logger.info("⚡ Microphone already disabled, skipping")
            return
        }
        
        logger.info("🎤 Disabling microphone")
        stopMicrophone()
    }
    
    func enableSystemAudio() {
        guard !isSystemAudioEnabled else {
            logger.info("⚡ System audio already enabled, skipping")
            return
        }
        
        logger.info("💻 Enabling system audio")
        startSystemAudio()
    }
    
    func disableSystemAudio() {
        guard isSystemAudioEnabled else {
            logger.info("⚡ System audio already disabled, skipping")
            return
        }
        
        logger.info("💻 Disabling system audio")
        stopSystemAudio()
    }
    
    func toggleMicrophone() {
        if isMicrophoneEnabled {
            disableMicrophone()
        } else {
            enableMicrophone()
        }
    }
    
    func toggleSystemAudio() {
        if isSystemAudioEnabled {
            disableSystemAudio()
        } else {
            enableSystemAudio()
        }
    }


    // MARK: - Microphone Control
    
    private func startMicrophone() {
        logger.info("🎤 STARTING MICROPHONE SOURCE via MicAudioManager")
        
        Task {
            await micAudioManager.start()
            
            await MainActor.run {
                if micAudioManager.isRecording {
                    self.isMicrophoneEnabled = true
                    // Create/replace consumer if aggregator is active
                    self.createMicrophoneConsumer()
                    self.logger.info("✅ MICROPHONE SOURCE STARTED via MicAudioManager")
                } else {
                    self.logger.error("❌ MicAudioManager failed to start recording")
                }
            }
        }
    }
    
    private func stopMicrophone() {
        logger.info("🎤 STOPPING MICROPHONE SOURCE via MicAudioManager")
        
        // Tear down consumer first
        destroyMicrophoneConsumer()
        // Stop MicAudioManager
        micAudioManager.stop()
        isMicrophoneEnabled = false
        
        logger.info("✅ MICROPHONE SOURCE STOPPED via MicAudioManager")
    }

    // MARK: - System Audio Control
    
    private func startSystemAudio() {
        guard #available(macOS 14.4, *) else {
            logger.warning("💻 System audio not supported on this macOS version")
            return
        }
        
        guard let systemAudioManager = systemAudioManager else {
            logger.error("💻 System audio manager not available")
            return
        }
        
        logger.info("💻 STARTING SYSTEM AUDIO SOURCE")
        
        Task {
            do {
                try await systemAudioManager.startCapture()
                
                await MainActor.run {
                    self.isSystemAudioEnabled = true
                    // Create/replace consumer if aggregator is active
                    self.createSystemAudioConsumer()
                    self.logger.info("✅ SYSTEM AUDIO SOURCE STARTED")
                }
                
            } catch {
                await MainActor.run {
                    self.logger.error("❌ System audio start error: \(error)")
                }

            }
        }
    }
    
    private func stopSystemAudio() {
        logger.info("💻 STOPPING SYSTEM AUDIO SOURCE")
        
        // Tear down consumer first
        destroySystemAudioConsumer()
        systemAudioManager?.stopCapture()
        isSystemAudioEnabled = false
        
        logger.info("✅ SYSTEM AUDIO SOURCE STOPPED")
    }
    
    // MARK: - Dynamic Consumer Management
    
    private func createMicrophoneConsumer() {
        // Cancel existing consumer if any
        destroyMicrophoneConsumer()
        
        guard isMicrophoneEnabled else { return }
        guard streamContinuation != nil else { return }
        
        logger.info("🎤 Creating microphone consumer")
        microphoneConsumerTask = Task { [weak self] in
            guard let self = self else { return }
            let micStream = self.micAudioManager.audioFramesWithVAD()
            for await micFrame in micStream {
                if Task.isCancelled { break }
                if self.shouldForwardFrame(micFrame, source: .microphone) {
                    self.streamContinuation?.yield(micFrame)
                }
            }
            self.logger.info("🎤 Microphone consumer ended")
        }
    }
    
    private func destroyMicrophoneConsumer() {
        microphoneConsumerTask?.cancel()
        microphoneConsumerTask = nil
        logger.info("🎤 Microphone consumer destroyed")
    }
    
    private func createSystemAudioConsumer() {
        // Cancel existing consumer if any
        destroySystemAudioConsumer()
        
        guard isSystemAudioEnabled else { return }
        guard streamContinuation != nil else { return }
        
        guard #available(macOS 14.4, *), let systemAudioManager = systemAudioManager else { return }
        
        logger.info("💻 Creating system audio consumer")
        systemAudioConsumerTask = Task { [weak self] in
            guard let self = self else { return }
            let systemStream = systemAudioManager.systemAudioStreamWithVAD()
            for await systemFrame in systemStream {
                if Task.isCancelled { break }
                if self.shouldForwardFrame(systemFrame, source: .systemAudio) {
                    self.streamContinuation?.yield(systemFrame)
                }
            }
            self.logger.info("💻 System audio consumer ended")
        }
    }
    
    private func destroySystemAudioConsumer() {
        systemAudioConsumerTask?.cancel()
        systemAudioConsumerTask = nil
        logger.info("💻 System audio consumer destroyed")
    }
    
    // MARK: - Stream Coordination
    
    func audioFrameStream() -> AsyncStream<AudioFrameWithVAD> {
        AsyncStream { continuation in
            // Store aggregator continuation
            self.streamContinuation = continuation
            self.logger.info("🔌 Aggregator stream created")
            
            // If sources are already active, create consumers now
            if self.isMicrophoneEnabled { self.createMicrophoneConsumer() }
            if self.isSystemAudioEnabled { self.createSystemAudioConsumer() }
            
            continuation.onTermination = { @Sendable [weak self] _ in
                guard let self = self else { return }
                self.destroyMicrophoneConsumer()
                self.destroySystemAudioConsumer()
                self.streamContinuation = nil
                self.logger.info("🛑 Aggregator stream terminated")
            }
        }
    }
    
    // MARK: - Stream Router Logic
    
    private func shouldForwardFrame(_ frame: AudioFrameWithVAD, source: AudioSource) -> Bool {
        // Fast returns if source disabled
        if source == .microphone && !isMicrophoneEnabled { return false }
        if source == .systemAudio && !isSystemAudioEnabled { return false }

        // If only one source enabled, always forward it and mark active
        if isMicrophoneEnabled && !isSystemAudioEnabled {
            return source == .microphone
        }
        if isSystemAudioEnabled && !isMicrophoneEnabled {
            return source == .systemAudio
        }

        // From here, both sources are enabled → apply arbitration
        // Update per-source last speech timestamps
        let now = Date()
        if frame.isSpeech {
            if source == .microphone { lastSpeechAtMic = now } else { lastSpeechAtSystem = now }
        }

        // Both enabled: apply arbitration
        // Initialize active if none and current frame is speech
        if activeSource == nil {
            if frame.isSpeech {
                activeSource = source
                activeSince = now
                logger.info("🎚️ Selecting initial active source: \(source.rawValue)")
                return true
            } else {
                // Wait for speech from either source
                return false
            }
        }

        guard let currentActive = activeSource, let since = activeSince else {
            // Shouldn't happen, but be safe
            activeSource = source
            activeSince = now
            return source == activeSource
        }

        // If this frame belongs to the active source, forward
        if source == currentActive {
            return true
        }

        // Consider switching to the other source
        let timeOnActive = now.timeIntervalSince(since)
        if timeOnActive < minActiveWindow {
            // Respect minimum active window
            return false
        }

        // Determine last speech time for the current active source
        let lastSpeechActive: Date? = (currentActive == .microphone) ? lastSpeechAtMic : lastSpeechAtSystem
        let silentDuration = lastSpeechActive.map { now.timeIntervalSince($0) } ?? .greatestFiniteMagnitude

        // Switch if active has been silent long enough and the other source is speaking now
        if silentDuration >= silenceToSwitch && frame.isSpeech {
            activeSource = source
            activeSince = now
            logger.info("🔀 Switching active source to: \(source.rawValue) after \(String(format: "%.1f", silentDuration))s silence on \(currentActive.rawValue)")
            return true
        }

        return false
    }
    

} 
