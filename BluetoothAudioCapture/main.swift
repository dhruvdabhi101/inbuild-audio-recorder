import Foundation
import AVFoundation
import AudioToolbox

// Global state
var audioUnit: AudioComponentInstance?
var isRunning = true
var outputFile: FileHandle?

// Audio format settings
let sampleRate: Float64 = 44100.0
let channels: UInt32 = 2
let bytesPerSample: UInt32 = 2

// Context struct to hold data for callback
class AudioCaptureContext {
    var audioUnit: AudioComponentInstance?
}

let captureContext = AudioCaptureContext()

// MARK: - Audio callback function
func recordingCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    // Create an AudioBufferList to hold the captured audio
    let bufferSize = inNumberFrames * channels * bytesPerSample
    var bufferList = AudioBufferList()
    bufferList.mNumberBuffers = 1
    
    var buffer = AudioBuffer()
    buffer.mNumberChannels = channels
    buffer.mDataByteSize = bufferSize
    buffer.mData = malloc(Int(bufferSize))
    
    bufferList.mBuffers = buffer
    
    // Get the audio unit from the context
    let context = Unmanaged<AudioCaptureContext>.fromOpaque(inRefCon).takeUnretainedValue()
    guard let audioUnit = context.audioUnit else {
        print("Error: Audio unit not available in callback")
        if let data = buffer.mData {
            free(data)
        }
        return -1
    }
    
    // Render the audio data
    let status = AudioUnitRender(
        audioUnit,
        ioActionFlags,
        inTimeStamp,
        inBusNumber,
        inNumberFrames,
        &bufferList
    )
    
    // If rendering was successful, write the data to stdout or file
    if status == noErr {
        if let data = buffer.mData {
            let audioData = Data(bytes: data, count: Int(bufferSize))
            
            // Write to output file or stdout
            if let fileHandle = outputFile {
                fileHandle.write(audioData)
            } else {
                FileHandle.standardOutput.write(audioData)
            }
        }
    } else {
        print("Render error: \(status)")
    }
    
    // Free the buffer
//    if let data = buffer.mData {
//        free(data)
//    }
    free(buffer.mData!)
    
    return noErr
}

// MARK: - Get audio devices
func getAudioDevices() -> [AudioDeviceID] {
    var propertySize: UInt32 = 0
    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    
    // Get the size of the device list
    var status = AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject),
        &propertyAddress,
        0,
        nil,
        &propertySize
    )
    
    if status != noErr {
        print("Error getting device list size: \(status)")
        return []
    }
    
    let deviceCount = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
    var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
    
    // Get the device list
    status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &propertyAddress,
        0,
        nil,
        &propertySize,
        &deviceIDs
    )
    
    if status != noErr {
        print("Error getting device list: \(status)")
        return []
    }
    
    return deviceIDs
}

// MARK: - Check if device has output streams
func deviceHasOutput(_ deviceID: AudioDeviceID) -> Bool {
    var propertySize: UInt32 = 0
    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    
    // Get property size
    var status = AudioObjectGetPropertyDataSize(
        deviceID,
        &propertyAddress,
        0,
        nil,
        &propertySize
    )
    
    if status != noErr {
        return false
    }
    
    // Get stream configuration
    let bufferListPtr = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(propertySize))
    defer {
        bufferListPtr.deallocate()
    }
    
    status = AudioObjectGetPropertyData(
        deviceID,
        &propertyAddress,
        0,
        nil,
        &propertySize,
        bufferListPtr
    )
    
    if status != noErr {
        return false
    }
    
    let bufferList = bufferListPtr.pointee
    let numBuffers = Int(bufferList.mNumberBuffers)
    
    // Check if any buffer has channels
    for i in 0..<numBuffers {
        let buffer = bufferList.mBuffers
        if buffer.mNumberChannels > 0 {
            return true
        }
    }
    
    return false
}

// MARK: - Get device information
func getDeviceInfo(for deviceID: AudioDeviceID) -> [String: Any] {
    var info: [String: Any] = ["id": deviceID]
    
    // Get device name
    info["name"] = getDeviceName(for: deviceID)
    
    // Check if device has output streams
    info["hasOutput"] = deviceHasOutput(deviceID)
    
    // Get sample rate
    var propertySize = UInt32(MemoryLayout<Float64>.size)
    var sampleRate: Float64 = 0.0
    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    
    let status = AudioObjectGetPropertyData(
        deviceID,
        &propertyAddress,
        0,
        nil,
        &propertySize,
        &sampleRate
    )
    
    if status == noErr {
        info["sampleRate"] = sampleRate
    }
    
    return info
}

// MARK: - Get device name
func getDeviceName(for deviceID: AudioDeviceID) -> String {
    var nameSize: UInt32 = 0
    var nameAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    
    var status = AudioObjectGetPropertyDataSize(deviceID, &nameAddress, 0, nil, &nameSize)
    var name = [CChar](repeating: 0, count: Int(nameSize))
    
    status = AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &name)
    return String(cString: name)
}

// MARK: - List available devices
func listAvailableDevices() {
    let devices = getAudioDevices()
    
    print("Available audio devices:")
    for (index, deviceID) in devices.enumerated() {
        let info = getDeviceInfo(for: deviceID)
        let name = info["name"] as? String ?? "Unknown"
        let hasOutput = info["hasOutput"] as? Bool ?? false
        let sampleRate = info["sampleRate"] as? Float64 ?? 0.0
        
        print("[\(index)] Device ID: \(deviceID), Name: \(name)")
        print("    Has Output: \(hasOutput), Sample Rate: \(sampleRate) Hz")
    }
}

// MARK: - Setup audio capture
func setupAudioCapture(deviceID: AudioDeviceID) -> Bool {
    // Check if device exists and has output streams
    let info = getDeviceInfo(for: deviceID)
    let hasOutput = info["hasOutput"] as? Bool ?? false
    
    if !hasOutput {
        print("Error: Selected device does not have output streams")
        return false
    }
    
    print("Setting up capture for device: \(info["name"] as? String ?? "Unknown")")
    
    // Create an audio component description for the HAL output unit
    var audioComponentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Output,
        componentSubType: kAudioUnitSubType_HALOutput,
        componentManufacturer: kAudioUnitManufacturer_Apple,
        componentFlags: 0,
        componentFlagsMask: 0
    )
    
    // Find the audio component
    guard let audioComponent = AudioComponentFindNext(nil, &audioComponentDescription) else {
        print("Error: Could not find audio component")
        return false
    }
    
    // Create a new audio unit instance
    var status = AudioComponentInstanceNew(audioComponent, &audioUnit)
    guard status == noErr, let audioUnit = audioUnit else {
        print("Error: Could not create audio unit instance: \(status)")
        return false
    }
    
    // Store the audio unit in our context for callback access
    captureContext.audioUnit = audioUnit
    
    // Set the audio device - important to do this first
    var deviceIDValue = deviceID
    status = AudioUnitSetProperty(
        audioUnit,
        kAudioOutputUnitProperty_CurrentDevice,
        kAudioUnitScope_Global,
        0,
        &deviceIDValue,
        UInt32(MemoryLayout<AudioDeviceID>.size)
    )
    
    if status != noErr {
        print("Error: Failed to set device: \(status)")
        return false
    }
    
    // Now we can configure IO - first enable input from the device's output
    var enableIO: UInt32 = 1
    
    // Enable input (we're getting audio output from the device as our input)
    status = AudioUnitSetProperty(
        audioUnit,
        kAudioOutputUnitProperty_EnableIO,
        kAudioUnitScope_Input,
        1, // input element
        &enableIO,
        UInt32(MemoryLayout<UInt32>.size)
    )
    
    if status != noErr {
        print("Error: Failed to enable input: \(status)")
        return false
    }
    
    // Disable output to the default device as we only want to capture
    enableIO = 0
    status = AudioUnitSetProperty(
        audioUnit,
        kAudioOutputUnitProperty_EnableIO,
        kAudioUnitScope_Output,
        0, // output element
        &enableIO,
        UInt32(MemoryLayout<UInt32>.size)
    )
    
    if status != noErr {
        print("Warning: Failed to disable output: \(status)")
        // This error is non-fatal, we can continue
    }
    
    var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var deviceFormat = AudioStreamBasicDescription()
        status = AudioUnitGetProperty(
            audioUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            1,
            &deviceFormat,
            &formatSize
        )
    
    // Set up the audio format for the output we want to capture
    var audioFormat = AudioStreamBasicDescription()
    audioFormat.mSampleRate = sampleRate
    audioFormat.mFormatID = kAudioFormatLinearPCM
    audioFormat.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
    audioFormat.mBitsPerChannel = 8 * bytesPerSample
    audioFormat.mChannelsPerFrame = channels
    audioFormat.mFramesPerPacket = 1
    audioFormat.mBytesPerFrame = bytesPerSample * channels
    audioFormat.mBytesPerPacket = bytesPerSample * channels
    
    // Set the stream format for input bus
    status = AudioUnitSetProperty(
        audioUnit,
        kAudioUnitProperty_StreamFormat,
        kAudioUnitScope_Output,
        0, // Input bus
        &audioFormat,
        UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    )
    
    guard status == noErr else {
        print("Error: Failed to set input stream format: \(status)")
        return false
    }
    
    // Set the rendering callback using Unmanaged for proper reference management
    let contextPtr = Unmanaged.passUnretained(captureContext).toOpaque()
    var callbackStruct = AURenderCallbackStruct(
        inputProc: recordingCallback,
        inputProcRefCon: contextPtr
    )
    
    status = AudioUnitSetProperty(
        audioUnit,
        kAudioOutputUnitProperty_SetInputCallback,
        kAudioUnitScope_Global,
        0, // Input bus
        &callbackStruct,
        UInt32(MemoryLayout<AURenderCallbackStruct>.size)
    )
    
    guard status == noErr else {
        print("Error: Failed to set rendering callback: \(status)")
        return false
    }
    
    // Allocate buffer if needed (important for some devices)
//    var allocBuffer: UInt32 = 1
//    AudioUnitSetProperty(
//        audioUnit,
//        kAudioUnitProperty_ShouldAllocateBuffer,
//        kAudioUnitScope_Output,
//        1,
//        &allocBuffer,
//        UInt32(MemoryLayout<UInt32>.size)
//    )
    
    // Initialize the audio unit
    status = AudioUnitInitialize(audioUnit)
    guard status == noErr  else {
        print("Error: Failed to initialize audio unit: \(status)")
        return false
    }
    
    print("Audio capture setup completed successfully")
    return true
}

// MARK: - Start capturing
func startCapture() -> Bool {
    guard let audioUnit = audioUnit else {
        print("Error: Audio unit not initialized")
        return false
    }
    
    let status = AudioOutputUnitStart(audioUnit)
    if status != noErr {
        print("Error: Failed to start audio unit: \(status)")
        return false
    }
    
    print("Audio capture started")
    return true
}

// MARK: - Stop capturing
func stopCapture() {
    if let audioUnit = audioUnit {
        AudioOutputUnitStop(audioUnit)
        AudioUnitUninitialize(audioUnit)
        AudioComponentInstanceDispose(audioUnit)
    }
    
    if let fileHandle = outputFile, fileHandle !== FileHandle.standardOutput {
        fileHandle.closeFile()
    }
}

// MARK: - Setup signal handler
func setupSignalHandler() {
    signal(SIGINT) { _ in
        print("\nReceived interrupt signal, stopping capture...")
        isRunning = false
        stopCapture()
        exit(0)
    }
}

// MARK: - Main entry point
func main() {
    
    AVCaptureDevice.requestAccess(for: .audio) { granted in
            if !granted {
                print("Error: Audio permission denied. Please enable in System Preferences.")
                exit(1)
            }
        }
    // Parse command line arguments
    let arguments = CommandLine.arguments
    var deviceID: AudioDeviceID?
    var outputPath: String?
    var listDevices = false
    
    var i = 1
    while i < arguments.count {
        switch arguments[i] {
        case "-d", "--device":
            if i + 1 < arguments.count, let id = UInt32(arguments[i + 1]) {
                deviceID = AudioDeviceID(id)
                i += 2
            } else {
                print("Error: Missing device ID")
                exit(1)
            }
        case "-o", "--output":
            if i + 1 < arguments.count {
                outputPath = arguments[i + 1]
                i += 2
            } else {
                print("Error: Missing output file path")
                exit(1)
            }
        case "-l", "--list":
            listDevices = true
            i += 1
        case "-h", "--help":
            print("Usage: \(arguments[0]) [options]")
            print("Options:")
            print("  -d, --device ID    Specify the audio device ID to capture from")
            print("  -o, --output PATH  Specify the output file path (default: stdout)")
            print("  -l, --list         List available audio devices")
            print("  -h, --help         Display this help message")
            exit(0)
        default:
            print("Unknown option: \(arguments[i])")
            exit(1)
        }
    }
    
    // List devices if requested
    if listDevices {
        listAvailableDevices()
        exit(0)
    }
    
    // If no device ID specified, list devices and exit
    if deviceID == nil {
        print("No device ID specified. Available devices:")
        listAvailableDevices()
        print("\nUse -d or --device option to specify a device ID.")
        exit(0)
    }
    
    // Set up output file if specified
    if let path = outputPath {
        do {
            // Create file if it doesn't exist
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: nil)
            }
            outputFile = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        } catch {
            print("Error: Failed to open output file: \(error)")
            exit(1)
        }
    }
    
    // Setup signal handler for graceful shutdown
    setupSignalHandler()
    
    // Setup audio capture
    if let deviceID = deviceID {
        print("Starting audio capture from device ID: \(deviceID)...")
        
        if !setupAudioCapture(deviceID: deviceID) {
            print("Failed to setup audio capture")
            exit(1)
        }
        
        if !startCapture() {
            print("Failed to start audio capture")
            exit(1)
        }
        
        // Keep the process running
        while isRunning {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        }
    }
}

// Run the main function
main()
