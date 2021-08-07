//
//  Arm64DDCUitls.swift
//  MonitorControl
//
//  Created by @waydabber on 2021. 08. 07..
//  Copyright © 2021. MonitorControl. All rights reserved.
//

import Foundation
import IOKit
import os.log

class Arm64DDCUtils: NSObject {
  public struct IOregService {
    var edidUUID: String = ""
    var productName: String = ""
    var serialNumber: Int64 = 0
    var service: IOAVService?
  }

  public struct DisplayService {
    var displayID: CGDirectDisplayID = 0
    var service: IOAVService?
  }

  #if arch(arm64)
    public static let isArm64: Bool = true
  #else
    public static let isArm64: Bool = false
  #endif

  // This matches Displays to the right IOAVServices
  public static func getServiceMatches(displayIDs: [CGDirectDisplayID], ioregServicesForMatching: [IOregService]) -> [DisplayService] {
    var matchedServices: [DisplayService] = []

    // MARK: TODO - this is not the final logic

    for displayID in displayIDs {
      for ioregServiceForMatching in ioregServicesForMatching {
        if self.ioregMatchScore(displayID: displayID, ioregEdidUUID: ioregServiceForMatching.edidUUID, ioregProductName: ioregServiceForMatching.productName, ioregSerialNumber: ioregServiceForMatching.serialNumber) >= 4 {
          let matchedService = DisplayService(displayID: displayID, service: ioregServiceForMatching.service)
          matchedServices.append(matchedService)
        }
      }
    }
    return matchedServices
  }

  // Scores the likelihood of a display match based on EDID UUID, ProductName and SerialNumber from in ioreg, compared to DisplayCreateInfoDictionary.
  public static func ioregMatchScore(displayID: CGDirectDisplayID, ioregEdidUUID: String, ioregProductName: String = "", ioregSerialNumber: Int64 = 0) -> Int {
    var matchScore: Int = 0
    if let dictionary = (CoreDisplay_DisplayCreateInfoDictionary(displayID))?.takeRetainedValue() as NSDictionary? {
      if let kDisplayYearOfManufacture = dictionary[kDisplayYearOfManufacture] as? Int64, let kDisplayWeekOfManufacture = dictionary[kDisplayWeekOfManufacture] as? Int64, let kDisplayVendorID = dictionary[kDisplayVendorID] as? Int64, let kDisplayProductID = dictionary[kDisplayProductID] as? Int64, let kDisplayVerticalImageSize = dictionary[kDisplayVerticalImageSize] as? Int64, let kDisplayHorizontalImageSize = dictionary[kDisplayHorizontalImageSize] as? Int64 {
        struct KeyLoc {
          var key: String
          var loc: Int
        }
        let edidUUIDSearchKeys: [KeyLoc] = [
          // Vendor ID
          KeyLoc(key: String(format: "%04x", UInt16(kDisplayVendorID)).uppercased(), loc: 0),
          // Product ID
          KeyLoc(key: String(format: "%02x", UInt8((UInt16(kDisplayProductID) >> (0 * 8)) & 0xFF)).uppercased()
            + String(format: "%02x", UInt8((UInt16(kDisplayProductID) >> (1 * 8)) & 0xFF)).uppercased(), loc: 4),
          // Manufacture date
          KeyLoc(key: String(format: "%02x", UInt8(kDisplayWeekOfManufacture)).uppercased()
            + String(format: "%02x", UInt8(kDisplayYearOfManufacture - 1990)).uppercased(), loc: 19),
          // Image size
          KeyLoc(key: String(format: "%02x", UInt8(kDisplayHorizontalImageSize / 10)).uppercased()
            + String(format: "%02x", UInt8(kDisplayVerticalImageSize / 10)).uppercased(), loc: 30),
        ]
        for searchKey in edidUUIDSearchKeys where searchKey.key != "0000" && searchKey.key == ioregEdidUUID.prefix(searchKey.loc + 4).suffix(4) {
          matchScore += 1
        }
      }
      if ioregProductName != "", let nameList = dictionary["DisplayProductName"] as? [String: String], let name = nameList["en_US"] ?? nameList.first?.value, name.lowercased() == ioregProductName.lowercased() {
        matchScore += 1
      }
      if ioregSerialNumber != 0, let serial = dictionary[kDisplaySerialNumber] as? Int64, serial == ioregSerialNumber {
        matchScore += 1
      }
    }
    return matchScore
  }

  // Iterate to the next requested item in the ioreg tree
  static func ioregIterateToNext(ioregObjectName: String, iterator: inout io_iterator_t) -> io_service_t {
    var service: io_service_t = IO_OBJECT_NULL
    let name = UnsafeMutablePointer<CChar>.allocate(capacity: MemoryLayout<io_name_t>.size)
    defer {
      name.deallocate()
    }
    while true {
      service = IOIteratorNext(iterator)
      guard service != MACH_PORT_NULL else {
        service = IO_OBJECT_NULL
        break
      }
      guard IORegistryEntryGetName(service, name) == KERN_SUCCESS else {
        os_log("IORegistryEntryGetName error", type: .debug)
        service = IO_OBJECT_NULL
        break
      }
      if String(cString: name) == ioregObjectName {
        break
      }
    }
    return service
  }

  // Returns EDID UUDI, Product Name and Serial Number in an IOregService if it is found using the provided io_service_t pointing to a AppleCDC2 item in the ioreg tree
  static func getIORegServiceAppleCDC2Properties(service: io_service_t) -> IOregService? {
    if let unmanagedEdidUUID = IORegistryEntryCreateCFProperty(service, CFStringCreateWithCString(kCFAllocatorDefault, "EDID UUID", kCFStringEncodingASCII), kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively)), let edidUUID = unmanagedEdidUUID.takeRetainedValue() as? String {
      var ioregService = IOregService()
      ioregService.edidUUID = edidUUID
      if let unmanagedDisplayAttrs = IORegistryEntryCreateCFProperty(service, CFStringCreateWithCString(kCFAllocatorDefault, "DisplayAttributes", kCFStringEncodingASCII), kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively)), let displayAttrs = unmanagedDisplayAttrs.takeRetainedValue() as? NSDictionary, let productAttrs = displayAttrs.value(forKey: "ProductAttributes") as? NSDictionary {
        if let productName = productAttrs.value(forKey: "ProductName") as? String {
          ioregService.productName = productName
        }
        if let serialNumber = productAttrs.value(forKey: "SerialNumber") as? Int64 {
          ioregService.serialNumber = serialNumber
        }
      }
      return ioregService
    }
    return nil
  }

  // Sets up the service in an IOregService if it is found using the provided io_service_t pointing to a DCPAVServiceProxy item in the ioreg tree
  static func setIORegServiceDCPAVServiceProxy(service: io_service_t, ioregService: inout IOregService) -> Bool {
    if let unmanagedLocation = IORegistryEntryCreateCFProperty(service, CFStringCreateWithCString(kCFAllocatorDefault, "Location", kCFStringEncodingASCII), kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively)), let location = unmanagedLocation.takeRetainedValue() as? String {
      if location == "External" {
        ioregService.service = IOAVServiceCreateWithService(kCFAllocatorDefault, service)?.takeRetainedValue() as IOAVService
        return true
      }
    }
    return false
  }

  // Returns IOAVSerivces with associated display properties for matching logic
  public static func getIoregServicesForMatching() -> [IOregService] {
    var ioregServicesForMatching: [IOregService] = []
    let ioregRoot: io_registry_entry_t = IORegistryGetRootEntry(kIOMasterPortDefault)
    var iterator = io_iterator_t()
    guard IORegistryEntryCreateIterator(ioregRoot, "IOService", IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else {
      os_log("IORegistryEntryCreateIterator error", type: .debug)
      return ioregServicesForMatching
    }
    while true {
      let serviceAppleCLCD2 = self.ioregIterateToNext(ioregObjectName: "AppleCLCD2", iterator: &iterator)
      guard serviceAppleCLCD2 != IO_OBJECT_NULL else {
        break
      }
      // We will check if it has an EDID UUID. If so, then we take it as an external display
      if var ioregService = getIORegServiceAppleCDC2Properties(service: serviceAppleCLCD2) {
        //  We will now iterate further, looking for the belonging "DCPAVServiceProxy" service (which should follow "AppleCLCD2" somewhat closely)
        let serviceDCPAVServiceProxy = self.ioregIterateToNext(ioregObjectName: "DCPAVServiceProxy", iterator: &iterator)
        guard serviceDCPAVServiceProxy != IO_OBJECT_NULL else {
          break
        }
        // Let's now create an instance of IOAVService with this service and add it to the service store with the "AppleCLCD2" strings
        if self.setIORegServiceDCPAVServiceProxy(service: serviceDCPAVServiceProxy, ioregService: &ioregService) {
          ioregServicesForMatching.append(ioregService)
        }
      }
    }
    return ioregServicesForMatching
  }

  // Performs DDC read or write
  public static func performDDCCommunication(service: IOAVService?, send: inout [UInt8], reply: inout [UInt8], writeSleepTime: UInt32 = 10000, numofWriteCycles: UInt8 = 2, readSleepTime: UInt32 = 10000, numOfRetryAttemps: UInt8 = 3, retrySleepTime: UInt32 = 20000) -> Bool {
    var success: Bool = false
    guard service != nil else {
      os_log("performDDCCommunication missing IOAVService error", type: .debug)
      return success
    }
    var checkedsend: [UInt8] = [UInt8(0x80 | (send.count + 1)), UInt8(send.count)] + send + [0]
    checkedsend[checkedsend.count - 1] = Utils.checksum(chk: send.count == 1 ? 0x6E : 0x6E ^ 0x51, data: &checkedsend, start: 0, end: checkedsend.count - 2)
    for _ in 1 ... numOfRetryAttemps {
      for _ in 1 ... numofWriteCycles {
        usleep(writeSleepTime)
        if IOAVServiceWriteI2C(service, 0x37, 0x51, &checkedsend, UInt32(checkedsend.count)) == 0 {
          success = true
        }
      }
      if reply.count > 0 {
        usleep(readSleepTime)
        if IOAVServiceReadI2C(service, 0x37, 0x51, &reply, UInt32(reply.count)) == 0 {
          if Utils.checksum(chk: 0x50, data: &reply, start: 0, end: reply.count - 2) == reply[reply.count - 1] {
            success = true
          } else {
            success = false
          }
        }
      }
      if success {
        return success
      }
      usleep(retrySleepTime)
    }
    return success
  }
}
