#!/usr/bin/swift

/*
 * utils/mkdiskimage.swift
 *
 * Created by Simon Evans on 13/11/2015.
 * Copyright © 2015, 2016 Simon Evans. All rights reserved.
 *
 * Creates a disk file image of a hard drive with composed of:
 * bootsector + chainloader + kernel
 *
 * The sector offsets for the chainloader and kernel are patched
 * into the boot sector along with the hard drive (0x80) which is used
 * for BIOS extended LBA loading. The diskimage is suitable for qemu
 * and bochs.
 *
 * On linux, the image can also be written to a raw parition (eg /dev/sda3)
 * as long as the drive has an MBR bootsector to get the LBA of the
 * partition and the partition type is set to 0x52
 */

import Foundation


let args = Process.arguments
guard args.count == 5 else {
      fatalError("usage: \(args[0]) <bootsector.bin> <loader.bin> <kernel.bin> <output>")
}
print("Bootsect: \(args[1]) loader: \(args[2]) kernel: \(args[3]) output: \(args[4])")

func openOrQuit(filename: String) -> NSData {
    guard let file = NSData(contentsOfFile: filename) else {
        fatalError("Cant open \(filename)")
    }
    return file
}


func patchValue<T>(data: NSData, offset: Int, value: T) {
    guard offset >= 0 && offset < data.length else {
        fatalError("Invalid offset: \(offset)")
    }
    let ptr = UnsafeMutablePointer<T>(data.bytes + offset)
    ptr.memory = value
}


func writeOutImage(filename: String, _ bootsect: NSData, _ loader: NSData, _ kernel: NSData, _ kernelLBA: Int) {
    let outputData = NSMutableData(data: bootsect)
    outputData.appendData(loader)

    // Make sure kernel starts on a sector boundary
    let seek = (outputData.length + 511) & ~511
    let kernelPadding = seek - outputData.length
    guard kernelPadding < 512 else {
        fatalError("kernel padding too much \(kernelPadding)")
    }
    print("Adding \(kernelPadding) bytes to start of kernel")
    outputData.increaseLengthBy(kernelPadding)
    outputData.appendData(kernel)

    // FIXME: make padding a cmd line arg, this is needed to make a bochs disk image
    let padding = (20 * 16 * 63 * 512)
    outputData.increaseLengthBy(padding - outputData.length)

    guard outputData.writeToFile(filename, atomically: false) else {
        fatalError("Cant write to output file \(filename)");
    }
}


// break a device name eg /dev/sda3 into /dev/sda and 3
func driveAndPartition(device: String) -> (String, Int?) {
    let devname = NSString(string: device)
    let numbers = NSCharacterSet.decimalDigitCharacterSet()
    let offset = devname.rangeOfCharacterFromSet(numbers)

    if offset.length == 0 {
        return (device, nil)
    } else {
        let newDevice = devname.substringToIndex(offset.location)
        let partition = Int(devname.substringFromIndex(offset.location))
        return (newDevice, partition)
    }
}


func getPartitionLBA(device: String) -> UInt64 {
    var stat_buf = stat_info()

    let ndevice = NSString(string: device)
    let cname  = ndevice.cStringUsingEncoding(NSASCIIStringEncoding)
    let err = stat(cname, &stat_buf)
    guard err == 0 else {
        print("Cant read device information for \(device)")
        return 0
    }
    let isDev: UInt32 = 0o60000

    guard (stat_buf.st_mode & isDev) == isDev else {
        print("\(device): not a block device")
        return 0;
    }
    let (dev, partition) = driveAndPartition(device)
    print("newDevice: #\(dev)# partition: #\(partition)#")
    guard partition != nil && partition > 0 else {
        fatalError("Block device is not a partition")
    }
    let partitionIdx = partition! - 1
    guard let fh = NSFileHandle(forReadingAtPath: dev) else {
        fatalError("Cant open \(dev) for reading")
    }

    let mbr = NSMutableData(length: 512)!
    guard read(fh.fileDescriptor, mbr.mutableBytes, 512) == 512 else {
        fatalError("Cant read MBR")
    }
    let ptRange = NSMakeRange(0x1be, strideof(hd_partition) * 4)
    let partitionTable = UnsafePointer<hd_partition>(mbr.subdataWithRange(ptRange).bytes)
    let partitionInfo = partitionTable[partitionIdx]
    print("system: \(partitionInfo.system) LBA: \(partitionInfo.LBA_start)")
    guard partitionInfo.system == 0x52 else {
        fatalError("Disk partition not set to correct type: 0x52 (CP/M)")
    }
    return UInt64(partitionInfo.LBA_start)
}

let bootsect = openOrQuit(args[1])
guard bootsect.length == 512 else {
    fatalError("Bootsector should be 512 bytes but is \(bootsect.length)")
}

// Ensure bootsector + loader == 2048 bytes so that if loaded from cd it fits in one
// ISO9660 sector
let loader = openOrQuit(args[2])
let loaderLen = (2048 - 512)
guard loader.length == (loaderLen) else {
    fatalError("Loader should be \(loaderLen) bytes but is \(loader.length)")
}

let kernel = openOrQuit(args[3])
let loaderSectors = UInt16((loader.length + 511) / 512)
let kernelSectors = UInt16((kernel.length + 511) / 512)
let loaderLBA = getPartitionLBA(args[4]) + 1
let kernelLBA = loaderLBA + UInt64(loaderSectors)

print("Loader: LBA: \(loaderLBA) sectors:\(loaderSectors)  kernel: LBA:\(kernelLBA) sectors:\(kernelSectors)")

// Patch in LBA and sector counts
patchValue(bootsect, offset: 482, value: loaderSectors.littleEndian)
patchValue(bootsect, offset: 488, value: loaderLBA.littleEndian)
patchValue(bootsect, offset: 496, value: kernelLBA.littleEndian)
patchValue(bootsect, offset: 504, value: kernelSectors.littleEndian)

writeOutImage(args[4], bootsect, loader, kernel, Int(kernelLBA))
