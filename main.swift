// vzgpu probe: boot a Linux guest under Virtualization.framework with a
// VZCustomVirtioDevice that claims to be virtio-gpu (device ID 16), and answer
// the control queue with a minimal 2D responder. Goal: prove the guest binds
// virtio_gpu to a custom device and that queue round-trips work.
//
// usage: vzgpu <vmdir>   (vmdir holds Image, initramfs.img, disk.img; console
// goes to <vmdir>/run/console.log, input is read from <vmdir>/run/in.fifo)

import Foundation
import Virtualization

func log(_ s: String) {
    let ts = String(format: "%.3f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000))
    FileHandle.standardError.write("[vmm \(ts)] \(s)\n".data(using: .utf8)!)
}

// virtio-gpu wire constants (include/uapi/linux/virtio_gpu.h)
let VIRTIO_GPU_FLAG_FENCE: UInt32 = 1
let VIRTIO_GPU_CMD_GET_DISPLAY_INFO: UInt32 = 0x0100
let VIRTIO_GPU_RESP_OK_NODATA: UInt32 = 0x1100
let VIRTIO_GPU_RESP_OK_DISPLAY_INFO: UInt32 = 0x1101
let VIRTIO_GPU_RESP_ERR_UNSPEC: UInt32 = 0x1200
let cmdNames: [UInt32: String] = [
    0x0100: "GET_DISPLAY_INFO", 0x0101: "RESOURCE_CREATE_2D", 0x0102: "RESOURCE_UNREF",
    0x0103: "SET_SCANOUT", 0x0104: "RESOURCE_FLUSH", 0x0105: "TRANSFER_TO_HOST_2D",
    0x0106: "RESOURCE_ATTACH_BACKING", 0x0107: "RESOURCE_DETACH_BACKING",
    0x0108: "GET_CAPSET_INFO", 0x0109: "GET_CAPSET", 0x010a: "GET_EDID",
    0x0300: "UPDATE_CURSOR", 0x0301: "MOVE_CURSOR",
]

final class GPUDevice: NSObject, VZCustomVirtioDeviceConfigurationDelegate, VZCustomVirtioDeviceDelegate {
    var device: VZCustomVirtioDevice?
    var counts: [UInt32: Int] = [:]

    func customVirtioConfiguration(_ configuration: VZCustomVirtioDeviceConfiguration,
                                   didCreateDevice device: VZCustomVirtioDevice) {
        log("custom device created; shm regions=\(device.sharedMemoryRegions.count)")
        self.device = device
        device.delegate = self
    }

    func customVirtioDeviceDidAcceptDriverOk(_ device: VZCustomVirtioDevice) {
        let f = device.negotiatedFeatures
        log(String(format: "DRIVER_OK; negotiated features subset0=0x%08x subset1=0x%08x",
                   f?.subset0 ?? 0, f?.subset1 ?? 0))
    }

    func customVirtioDeviceWillReset(_ device: VZCustomVirtioDevice) { log("device reset") }
    func customVirtioDeviceWillStop(_ device: VZCustomVirtioDevice) { log("device stop") }

    func customVirtioDevice(_ device: VZCustomVirtioDevice, didReceiveNotificationFor queue: VZVirtioQueue) {
        while let el = queue.nextElement() {
            handle(queue: queue.queueIndex, el)
            el.returnToQueue()
        }
    }

    func handle(queue: UInt16, _ el: VZVirtioQueueElement) {
        var hdr = [UInt8](repeating: 0, count: 24)
        do {
            try el.readBytes(intoBuffer: &hdr, exactLength: 24)
        } catch {
            log("q\(queue): short request (\(el.readBuffersByteCount) bytes): \(error)")
            return
        }
        let type = hdr.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
        let flags = hdr.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
        counts[type, default: 0] += 1
        if counts[type]! <= 3 || counts[type]! % 1000 == 0 {
            log("q\(queue): \(cmdNames[type] ?? String(format: "0x%04x", type)) #\(counts[type]!) "
                + "req=\(el.readBuffersByteCount)B resp=\(el.writeBuffersByteCount)B flags=\(flags)")
        }
        if queue == 1 { return }  // cursor queue: no response buffer

        var resp: [UInt8]
        if type == VIRTIO_GPU_CMD_GET_DISPLAY_INFO {
            // ctrl_hdr + 16 x { rect{x,y,w,h}, enabled, flags }
            resp = [UInt8](repeating: 0, count: 24 + 16 * 24)
            resp.withUnsafeMutableBytes { p in
                p.storeBytes(of: VIRTIO_GPU_RESP_OK_DISPLAY_INFO, toByteOffset: 0, as: UInt32.self)
                p.storeBytes(of: UInt32(1280), toByteOffset: 24 + 8, as: UInt32.self)
                p.storeBytes(of: UInt32(800), toByteOffset: 24 + 12, as: UInt32.self)
                p.storeBytes(of: UInt32(1), toByteOffset: 24 + 16, as: UInt32.self)
            }
        } else {
            let known = cmdNames[type] != nil && type != 0x0108 && type != 0x0109 && type != 0x010a
            resp = [UInt8](repeating: 0, count: 24)
            resp.withUnsafeMutableBytes {
                $0.storeBytes(of: known ? VIRTIO_GPU_RESP_OK_NODATA : VIRTIO_GPU_RESP_ERR_UNSPEC,
                              toByteOffset: 0, as: UInt32.self)
            }
        }
        if flags & VIRTIO_GPU_FLAG_FENCE != 0 {  // echo fence id, ctx id, ring idx
            resp.replaceSubrange(4..<24, with: hdr[4..<24])
        }
        let n = min(resp.count, el.writeBuffersByteCount)
        do {
            try el.writeBuffer(&resp, exactLength: n)
        } catch {
            log("q\(queue): response write failed: \(error)")
        }
    }
}

final class VMDelegate: NSObject, VZVirtualMachineDelegate {
    func guestDidStop(_ vm: VZVirtualMachine) { log("guest stopped"); exit(0) }
    func virtualMachine(_ vm: VZVirtualMachine, didStopWithError error: Error) {
        log("VM stopped with error: \(error)"); exit(1)
    }
}

let args = CommandLine.arguments
guard args.count == 2 else { print("usage: vzgpu <vmdir>"); exit(2) }
let dir = URL(fileURLWithPath: args[1])
let runDir = dir.appendingPathComponent("run")
try? FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)

let defaultCmdline = [
    "console=hvc0", "root=UUID=96ff3c27-158a-4f65-a5a8-2c3344757f97", "rootflags=subvol=root", "ro",
    "systemd.unit=multi-user.target", "systemd.debug_shell=hvc0",
    "systemd.mask=serial-getty@hvc0.service", "systemd.firstboot=off",
].joined(separator: " ")
let cmdline = ProcessInfo.processInfo.environment["VZGPU_CMDLINE"] ?? defaultCmdline

let boot = VZLinuxBootLoader(kernelURL: dir.appendingPathComponent("Image"))
boot.initialRamdiskURL = dir.appendingPathComponent("initramfs.img")
boot.commandLine = cmdline

let config = VZVirtualMachineConfiguration()
config.bootLoader = boot
config.platform = VZGenericPlatformConfiguration()
config.cpuCount = 4
config.memorySize = 4 << 30

let disk = try VZDiskImageStorageDeviceAttachment(url: dir.appendingPathComponent("disk.img"), readOnly: false)
config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: disk)]

let net = VZVirtioNetworkDeviceConfiguration()
net.attachment = VZNATNetworkDeviceAttachment()
config.networkDevices = [net]
config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

// Console: input from a FIFO (opened O_RDWR so it never sees EOF), output to a log file.
let fifoPath = runDir.appendingPathComponent("in.fifo").path
unlink(fifoPath)
mkfifo(fifoPath, 0o600)
let inFD = open(fifoPath, O_RDWR)
let logPath = runDir.appendingPathComponent("console.log").path
FileManager.default.createFile(atPath: logPath, contents: nil)
let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
serial.attachment = VZFileHandleSerialPortAttachment(
    fileHandleForReading: FileHandle(fileDescriptor: inFD),
    fileHandleForWriting: FileHandle(forWritingAtPath: logPath)!)
config.serialPorts = [serial]

// The custom virtio-gpu: 2 queues (control, cursor), display controller class,
// config = { events_read, events_clear, num_scanouts=1, num_capsets=0 }.
let gpu = GPUDevice()
let gpuQueue = DispatchQueue(label: "vzgpu.device")
let gpuConfig = VZCustomVirtioDeviceConfiguration()
gpuConfig.deviceID = 16
gpuConfig.pciClassID = 0x03
gpuConfig.pciSubclassID = 0x80
gpuConfig.virtioQueueCount = 2
var devcfg = [UInt8](repeating: 0, count: 16)
devcfg[8] = 1
gpuConfig.deviceSpecificConfiguration = VZVirtioDeviceSpecificConfiguration(configurationData: Data(devcfg))
gpuConfig.provider = VZCustomVirtioDeviceDelegateProvider(deviceQueue: gpuQueue, delegate: gpu)
config.customVirtioDevices = [gpuConfig]

do {
    try config.validate()
} catch {
    log("config validation failed: \(error)"); exit(1)
}
log("config valid; cmdline: \(cmdline)")

let vm = VZVirtualMachine(configuration: config)
let vmDelegate = VMDelegate()
vm.delegate = vmDelegate
vm.start { result in
    switch result {
    case .success: log("VM started")
    case .failure(let e): log("start failed: \(e)"); exit(1)
    }
}
RunLoop.main.run()
