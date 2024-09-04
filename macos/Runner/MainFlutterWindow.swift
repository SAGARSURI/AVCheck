import Cocoa
import FlutterMacOS
import CoreAudio
import AVFoundation

func audioChangeListenerCallback(objectID: UInt32, numAddresses: UInt32, addressesPtr: UnsafePointer<AudioObjectPropertyAddress>, clientData: UnsafeMutableRawPointer?) -> OSStatus {
    let welf = Unmanaged<MainFlutterWindow>.fromOpaque(clientData!).takeUnretainedValue()
    let address = addressesPtr.pointee
    print("Audio change detected: selector = \(address.mSelector), scope = \(address.mScope), element = \(address.mElement)")
    welf.notifyFlutterOfAudioChanges()
    return noErr
}

class MainFlutterWindow: NSWindow, AVCaptureAudioDataOutputSampleBufferDelegate {
    private var eventListenerHandle: UInt32 = 0
    private var flutterViewController: FlutterViewController!
    private var microphoneEventChannel: FlutterEventChannel!
    private var audioEventChannel: FlutterEventChannel!
    private var microphoneEventSink: FlutterEventSink?
    var audioEventSink: FlutterEventSink?
    private var methodChannel: FlutterMethodChannel!

        
    private var captureSession: AVCaptureSession?
    private var audioOutput: AVCaptureAudioDataOutput?
    private var recordingURL: URL?
    private var audioFileOutput: AVCaptureMovieFileOutput?
    private var audioPlayer: AVAudioPlayer?

    override func awakeFromNib() {
        flutterViewController = FlutterViewController.init()
                let windowFrame = self.frame
                self.contentViewController = flutterViewController
                self.setFrame(windowFrame, display: true)

                RegisterGeneratedPlugins(registry: flutterViewController)

                super.awakeFromNib()
                
                microphoneEventChannel = FlutterEventChannel(name: "com.example.microphone_detector/microphone_events",
                                                             binaryMessenger: flutterViewController.engine.binaryMessenger)
                microphoneEventChannel.setStreamHandler(self)
                
                audioEventChannel = FlutterEventChannel(name: "com.example.microphone_detector/audio_events",
                                                        binaryMessenger: flutterViewController.engine.binaryMessenger)
                audioEventChannel.setStreamHandler(AudioStreamHandler(mainWindow: self))
        
        methodChannel = FlutterMethodChannel(name: "com.example.microphone_detector/audio_control",
                                                 binaryMessenger: flutterViewController.engine.binaryMessenger)
            methodChannel.setMethodCallHandler { [weak self] call, result in
                guard let self = self else { return }
                switch call.method {
                case "startRecording":
                    self.startRecording()
                    result(nil)
                case "playRecording":
                    self.playRecording()
                    result(nil)
                default:
                    result(FlutterMethodNotImplemented)
                }
            }
    }

    func startRecording() {
            print("Starting recording")
            captureSession = AVCaptureSession()
            
            guard let audioDevice = AVCaptureDevice.default(for: .audio) else {
                print("No audio device available")
                self.audioEventSink?(["error": "No audio device available"])
                return
            }
            
            do {
                let audioInput = try AVCaptureDeviceInput(device: audioDevice)
                if captureSession!.canAddInput(audioInput) {
                    captureSession!.addInput(audioInput)
                }
                
                audioFileOutput = AVCaptureMovieFileOutput()
                if captureSession!.canAddOutput(audioFileOutput!) {
                    captureSession!.addOutput(audioFileOutput!)
                }
                
                let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
                let dateString = dateFormatter.string(from: Date())
                recordingURL = documentsPath.appendingPathComponent("testRecording_\(dateString).m4a")
                
                captureSession!.startRunning()
                audioFileOutput!.startRecording(to: recordingURL!, recordingDelegate: self)
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    self.stopRecording()
                }
            } catch {
                print("Failed to start recording: \(error)")
                self.audioEventSink?(["error": "Failed to start recording: \(error)"])
            }
        }
    
    private func deleteOldRecordings() {
        let fileManager = FileManager.default
        let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        
        do {
            let fileURLs = try fileManager.contentsOfDirectory(at: documentsPath, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            for fileURL in fileURLs where fileURL.lastPathComponent.hasPrefix("testRecording_") {
                try fileManager.removeItem(at: fileURL)
            }
        } catch {
            print("Error while deleting old recordings: \(error)")
        }
    }


    func stopRecording() {
            print("Stopping recording")
            audioFileOutput?.stopRecording()
            DispatchQueue.main.async { [weak self] in
                self?.captureSession?.stopRunning()
                print("Sending recordingFinished event")
                self?.audioEventSink?(["recordingFinished": true])
            }
        }



    func playRecording() {
            guard let recordingURL = recordingURL else {
                print("No recording available")
                self.audioEventSink?(["error": "No recording available"])
                return
            }
            
            do {
                audioPlayer = try AVAudioPlayer(contentsOf: recordingURL)
                audioPlayer?.play()
                self.audioEventSink?(["playbackStarted": true])
            } catch {
                print("Failed to play recording: \(error)")
                self.audioEventSink?(["error": "Failed to play recording: \(error)"])
            }
        }


    func notifyFlutterOfAudioChanges() {
            DispatchQueue.main.async {
                let microphones = self.getMicrophones()
                print("Sending microphones to Flutter: \(microphones)")
                self.microphoneEventSink?(microphones)
            }
        }

    private func getMicrophones() -> [[String: Any]] {
        var microphoneInfo: [[String: Any]] = []
        let defaultInputDeviceID = getDefaultInputDeviceID()
        
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize)
        
        if status != noErr {
            print("Error getting data size: \(status)")
            return microphoneInfo
        }
        
        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        
        status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &deviceIDs)
        
        if status != noErr {
            print("Error getting device IDs: \(status)")
            return microphoneInfo
        }
        
        for deviceID in deviceIDs {
            if isPhysicalInputDevice(deviceID) {
                if let deviceName = getDeviceName(deviceID) {
                    microphoneInfo.append([
                        "name": deviceName,
                        "isDefault": deviceID == defaultInputDeviceID,
                        "deviceID": deviceID,
                        "type": getDeviceType(deviceID),
                        "volume": getInputVolume(deviceID)
                    ])
                }
            }
        }
        
        return microphoneInfo
    }

    private func getInputVolume(_ deviceID: AudioDeviceID) -> Float {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMaster)
        
        // Check if the device has a volume control
        var hasVolume: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        var status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &hasVolume)
        
        if status != noErr || hasVolume == 0 {
            // If there's no volume control, check for a volume range
            address.mSelector = kAudioDevicePropertyVolumeScalarToDecibels
            status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
            if status != noErr {
                print("Device doesn't support volume control")
                return 1.0 // Assume full volume if no control is available
            }
        }
        
        // Get the volume
        var volume: Float = 0.0
        dataSize = UInt32(MemoryLayout<Float>.size)
        status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &volume)
        
        if status != noErr {
            print("Error getting input volume: \(status)")
            return 0.0
        }
        
        return volume
    }

    private func startListeningForAudioChanges() {
        let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        
        // Listen for default device changes
        var defaultDeviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        
        var status = AudioObjectAddPropertyListener(AudioObjectID(kAudioObjectSystemObject), &defaultDeviceAddress, audioChangeListenerCallback, selfPtr)
        
        if status != noErr {
            print("Error setting up default device change listener: \(status)")
        }
        
        // Listen for device list changes
        var deviceListAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        
        status = AudioObjectAddPropertyListener(AudioObjectID(kAudioObjectSystemObject), &deviceListAddress, audioChangeListenerCallback, selfPtr)
        
        if status != noErr {
            print("Error setting up device list change listener: \(status)")
        }
        
        // Listen for volume changes
        let defaultInputDeviceID = getDefaultInputDeviceID()
        var volumeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMaster)
        
        status = AudioObjectAddPropertyListener(defaultInputDeviceID, &volumeAddress, audioChangeListenerCallback, selfPtr)
        
        if status != noErr {
            print("Error setting up volume change listener: \(status)")
        }
    }

    private func stopListeningForAudioChanges() {
        let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        
        var defaultDeviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        
        var status = AudioObjectRemovePropertyListener(AudioObjectID(kAudioObjectSystemObject), &defaultDeviceAddress, audioChangeListenerCallback, selfPtr)
        
        if status != noErr {
            print("Error removing default device change listener: \(status)")
        }
        
        var deviceListAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        
        status = AudioObjectRemovePropertyListener(AudioObjectID(kAudioObjectSystemObject), &deviceListAddress, audioChangeListenerCallback, selfPtr)
        
        if status != noErr {
            print("Error removing device list change listener: \(status)")
        }
        
        let defaultInputDeviceID = getDefaultInputDeviceID()
        var volumeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMaster)
        
        status = AudioObjectRemovePropertyListener(defaultInputDeviceID, &volumeAddress, audioChangeListenerCallback, selfPtr)
        
        if status != noErr {
            print("Error removing volume change listener: \(status)")
        }
    }

    private func getDefaultInputDeviceID() -> AudioDeviceID {
        var defaultInputDeviceID: AudioDeviceID = 0
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &defaultInputDeviceID)
        
        if status != noErr {
            print("Error getting default input device: \(status)")
        }
        
        return defaultInputDeviceID
    }

    private func isPhysicalInputDevice(_ deviceID: AudioDeviceID) -> Bool {
        return isInputDevice(deviceID) && (isBuiltInDevice(deviceID) || isUSBDevice(deviceID) || isBluetoothDevice(deviceID))
    }

    private func isInputDevice(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        
        if status != noErr {
            return false
        }
        
        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(dataSize))
        defer { bufferList.deallocate() }
        
        status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, bufferList)
        
        if status != noErr {
            return false
        }
        
        let bufferList2 = UnsafeMutableAudioBufferListPointer(bufferList)
        return bufferList2.count > 0
    }

    private func isBuiltInDevice(_ deviceID: AudioDeviceID) -> Bool {
        return getDeviceTransportType(deviceID) == kAudioDeviceTransportTypeBuiltIn
    }

    private func isUSBDevice(_ deviceID: AudioDeviceID) -> Bool {
        return getDeviceTransportType(deviceID) == kAudioDeviceTransportTypeUSB
    }

    private func isBluetoothDevice(_ deviceID: AudioDeviceID) -> Bool {
        let transportType = getDeviceTransportType(deviceID)
        return transportType == kAudioDeviceTransportTypeBluetooth || transportType == kAudioDeviceTransportTypeBluetoothLE
    }

    private func getDeviceTransportType(_ deviceID: AudioDeviceID) -> UInt32 {
        var transportType: UInt32 = 0
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, &transportType)
        
        if status != noErr {
            print("Error getting device transport type: \(status)")
        }
        
        return transportType
    }

    private func getDeviceType(_ deviceID: AudioDeviceID) -> String {
        if isBuiltInDevice(deviceID) {
            return "Built-in"
        } else if isUSBDevice(deviceID) {
            return "USB"
        } else if isBluetoothDevice(deviceID) {
            return "Bluetooth"
        } else {
            return "Unknown"
        }
    }

    private func getDeviceName(_ deviceID: AudioDeviceID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        
        var deviceNameRef: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, &deviceNameRef)
        
        if status == noErr, let deviceNameRef = deviceNameRef {
            let deviceName = deviceNameRef.takeRetainedValue() as String
            return deviceName
        }
        
        return nil
    }

}

extension MainFlutterWindow: FlutterStreamHandler {
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        print("Flutter started listening to microphone events")
        self.microphoneEventSink = events
        startListeningForAudioChanges()
        notifyFlutterOfAudioChanges()
        return nil
    }
    
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        print("Flutter stopped listening to microphone events")
        self.microphoneEventSink = nil
        stopListeningForAudioChanges()
        return nil
    }
}

class AudioStreamHandler: NSObject, FlutterStreamHandler {
    weak var mainWindow: MainFlutterWindow?
    
    init(mainWindow: MainFlutterWindow) {
        self.mainWindow = mainWindow
    }
    
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        print("Flutter started listening to audio events")
        mainWindow?.audioEventSink = events
        return nil
    }
    
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        print("Flutter stopped listening to audio events")
        mainWindow?.audioEventSink = nil
        return nil
    }
}

extension MainFlutterWindow: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        print("fileOutput delegate called")
        if let error = error as NSError? {
            if error.domain == AVFoundationErrorDomain && error.code == -11806 {
                print("Recording finished successfully (with -11806 error)")
                self.audioEventSink?(["recordingFinished": true])
            } else {
                print("Error recording: \(error)")
                self.audioEventSink?(["error": "Error recording: \(error.localizedDescription)"])
            }
        } else {
            print("Recording finished successfully (without error)")
            self.audioEventSink?(["recordingFinished": true])
        }
    }
}


