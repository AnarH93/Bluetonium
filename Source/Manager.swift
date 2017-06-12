//
//  Manager.swift
//  Bluetonium
//
//  Created by Dominggus Salampessy on 23/12/15.
//  Copyright © 2015 E-sites. All rights reserved.
//

import Foundation
import CoreBluetooth

public class Manager: NSObject, CBCentralManagerDelegate {
    
    public var bluetoothEnabled: Bool {
        get {
            return centralManager?.state == .PoweredOn
        }
    }
    
    public var isStorred: Bool {
        get {
            return storedConnectedUUID != nil
        }
    }
    public var rssiForConnect: Int = -100
    
    public  static let shared: Manager = Manager()
    
    private(set) public var scanning = false
    private(set) public var connectedDevices: [Device] = []
    private(set) public var foundDevices: [CBPeripheral] = []
    public weak var delegate: ManagerDelegate?
    
    private var centralManager: CBCentralManager?
    private var disconnecting = false
    private let dispatchQueue = dispatch_queue_create(ManagerConstants.dispatchQueueLabel, nil)
    
    // MARK: Initializers
    
    public init(background: Bool = false) {
        super.init()
        
        let options: [String: String]? = background ? [CBCentralManagerOptionRestoreIdentifierKey: ManagerConstants.restoreIdentifier] : nil
        centralManager = CBCentralManager(delegate: self, queue: dispatchQueue, options: options)
    }
    
    // MARK: Public functions
    
    /**
     Start scanning for devices advertising with a specific service.
     The services can also be nil this will return all found devices.
     Found devices will be returned in the foundDevices array.
     
     - parameter services: The UUID of the service the device is advertising with, can be nil.
     */
    public func startScanForDevices(advertisingWithServices services: [String]? = nil) {
        
        scanning = true
        
        foundDevices.removeAll()
        centralManager?.scanForPeripheralsWithServices(services?.CBUUIDs(), options: nil)
    }
    
    /**
     Stop scanning for devices.
     Only possible when it's scanning.
     */
    public func stopScanForDevices() {
        scanning = false
        
        centralManager?.stopScan()
    }
    
    /**
     Connect with a device. This device is returned from the foundDevices list.
     
     - parameter device: The device to connect with.
     */
    public func connect(with device: Device) {
        // Only allow connecting when it's not yet connected to another device.
        foundDevices.append(device.peripheral)
        
        // Store connected UUID, to enable later connection to the same peripheral.
        store(connectedUUID: device.peripheral.identifier.UUIDString)
        
        dispatch_async(dispatch_get_main_queue()) { () -> Void in
            // Send callback to delegate.
            self.delegate?.manager(self, willConnectToDevice: device)
        }
        connect(to: device.peripheral)
    }
    
    /**
     Disconnect from the connected device.
     Only possible when not connected to a device.
     */
    public func disconnect(from device: Device) {
        // Reset stored UUID.
        store(connectedUUID: nil)
        
        let peripheral = device.peripheral
        
        if peripheral.state != .Connected {
            //connectedDevice = nil
        } else {
            disconnecting = true
            centralManager?.cancelPeripheralConnection(peripheral)
        }
    }
    
    // MARK: Private functions
    
    private func connect(to peripheral: CBPeripheral) {
        centralManager?.connectPeripheral(peripheral, options: [ CBConnectPeripheralOptionNotifyOnDisconnectionKey: NSNumber(bool: true) ])
    }
    
    /**
     Store the connectedUUID in the UserDefaults.
     This is to restore the connection after the app restarts or runs in the background.
     */
    private func store(connectedUUID uuid: String?) {
        
        //reuse or init
        var array = storedConnectedUUID != nil ? storedConnectedUUID! : [String]()
        
        guard let _uuid = uuid where array.contains(_uuid) else {
            return
        }
        
        //append new value
        array.append(_uuid)
        
        let defaults = NSUserDefaults.standardUserDefaults()
        defaults.setObject(array, forKey: ManagerConstants.UUIDStoreKey)
        defaults.synchronize()
    }
    
    /**
     Returns the stored UUID if there is one.
     */
    private var storedConnectedUUID:[String]? {
        return NSUserDefaults.standardUserDefaults().objectForKey(ManagerConstants.UUIDStoreKey) as? [String]
    }
    
    
    // MARK: CBCentralManagerDelegate
    
    @objc public func centralManager(central: CBCentralManager, willRestoreState dict: [String : AnyObject]) {
        print("willRestoreState: \(dict[CBCentralManagerRestoredStatePeripheralsKey])")
        let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral]
        peripherals?.forEach({ (peripheral) in
            let device = Device(peripheral: peripheral)
            if let delegate = self.delegate where
                delegate.manager(self, shouldConnectTo: device) {
                central.connectPeripheral(peripheral, options: nil)
            }
        })
    }
    
    @objc public func centralManagerDidUpdateState(central: CBCentralManager) {
        
        switch (central.state) {
        case .PoweredOn:
            connectedDevices.forEach({ (device) in
                if let delegate = self.delegate where
                    delegate.manager(self, shouldConnectTo: device) {
                    central.connectPeripheral(device.peripheral, options: [ CBConnectPeripheralOptionNotifyOnDisconnectionKey: NSNumber(bool: true) ])
                }
            })
            
            storedConnectedUUID?.forEach({ (uuid) in
                
                guard let uuid = NSUUID(UUIDString: uuid) else {
                    return
                }
                
                let peripherals = central.retrievePeripheralsWithIdentifiers([uuid])
                peripherals.forEach({ (peripheral) in
                    
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, Int64(0.2 * Double(NSEC_PER_SEC))), dispatchQueue) {
                        let device = Device(peripheral: peripheral)
                        
                        if let _delegate = self.delegate where _delegate.manager(self, shouldConnectTo: device) {
                            device.registerServiceManager()
                            self.connect(with: device)
                        }
                    }
                })
            })
            
        case .PoweredOff:
            dispatch_async(dispatch_get_main_queue()) { () -> Void in
                self.connectedDevices.forEach({ (device) in
                    device.serviceModelManager.resetServices()
                    self.delegate?.manager(self, disconnectedFromDevice: device, willRetry: false)
                })
            }
        default:
            break
        }
        
        dispatch_async(dispatch_get_main_queue()) { () -> Void in
            self.delegate?.managerDidUpdateState(ManagerState(rawValue: central.state.rawValue) ?? .Unknown)
        }
        
    }
    
    @objc public func centralManager(central: CBCentralManager, didDiscoverPeripheral peripheral: CBPeripheral, advertisementData: [String : AnyObject], RSSI: NSNumber) {
        
        guard Int(RSSI.intValue) > self.rssiForConnect else {
            return
        }
        
        let name = advertisementData["kCBAdvDataLocalName"] as? String
        
        let device = Device(peripheral: peripheral, with: name)
        
        guard let _delegate = delegate where _delegate.manager(self, shouldConnectTo: device, with: advertisementData) else {
            //это вообще бесплоезно, знаю, но чисто для теста одного бага на который мы потратили уже 3 месяца
            return
        }
        
        // Only after adding it to the list to prevent issues reregistering the delegate.
        device.registerServiceManager()
        
        dispatch_async(dispatch_get_main_queue()) { () -> Void in
            self.delegate?.manager(self, didFindDevice: device)
            self.delegate?.manager(self, didFindDevice: device, rssi: RSSI)
        }
        
        connect(with: device)
    }
    
    @objc public func centralManager(central: CBCentralManager, didConnectPeripheral peripheral: CBPeripheral) {
        let device = Device(peripheral: peripheral)
        guard let _delegate = delegate where _delegate.manager(self, shouldConnectTo: device) else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        
        connectedDevices.append(device)
        
        dispatch_async(dispatch_get_main_queue()) { () -> Void in
            // Send callback to delegate.
            self.delegate?.manager(self, connectedToDevice: device)
            
            // Start discovering services process after connecting to peripheral.
            device.serviceModelManager.discoverRegisteredServices()
        }
    }
    
    @objc public func centralManager(central: CBCentralManager, didFailToConnectPeripheral peripheral: CBPeripheral, error: NSError?) {
        print("didFailToConnect \(peripheral)")
        
        let device = Device(peripheral: peripheral)
        if let delegate = self.delegate where
            delegate.manager(self, shouldConnectTo: device) {
            connect(to: peripheral)
        }
    }
    
    @objc public func centralManager(central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: NSError?) {
        
        guard error == nil else {
            dispatch_async(dispatch_get_main_queue()) { () -> Void in
                self.delegate?.manager(self, disconnectedFromDevice: Device(peripheral: peripheral), willRetry: true)
            }
            connect(to: peripheral)
            return
        }
        
        let connectedPeripherals = connectedDevices.map { (device) -> CBPeripheral in
            return device.peripheral
        }
        
        var _index: Int? = nil //setup by default
        var connectedDevice = Device(peripheral: peripheral) //setup by default
        if let index = connectedPeripherals.indexOf(peripheral) {
            connectedDevice = connectedDevices[index]
            connectedDevice.serviceModelManager.resetServices()
            _index = index
        }
        
        dispatch_async(dispatch_get_main_queue()) { () -> Void in
            self.delegate?.manager(self, disconnectedFromDevice: connectedDevice, willRetry: true)
        }
        
        // Send reconnect command after peripheral disconnected.
        // It will connect again when it became available.
        
        if let delegate = self.delegate where
            delegate.manager(self, shouldConnectTo: connectedDevice) {
            connect(to: peripheral)
        }
        
        //remove from connected
        if let index = _index {
            connectedDevices.removeAtIndex(index)
        }
        
    }
    
}


public protocol ManagerDelegate: class {
    
    func manager(manager: Manager, shouldConnectTo peripheral: Device) -> Bool
    func manager(manager: Manager, shouldConnectTo peripheral: Device, with advertisementData: [String : AnyObject]) -> Bool
    /**
     Called when the `Manager` did find a peripheral and did add it to the foundDevices array.
     */
    func manager(manager: Manager, didFindDevice device: Device)
    
    /**
     Called when the `Manager` did find a peripheral and did add it to the foundDevices array.
     */
    func manager(manager: Manager, didFindDevice device: Device, rssi RSSI: NSNumber)
    
    /**
     Called when the `Manager` is trying to connect to device
     */
    func manager(manager: Manager, willConnectToDevice device: Device)
    
    /**
     Called when the `Manager` did connect to the device.
     */
    func manager(manager: Manager, connectedToDevice device: Device)
    
    /**
     Called when the `Manager` did disconnect from the device.
     Retry will indicate if the Manager will retry to connect when it becomes available.
     */
    func manager(manager: Manager, disconnectedFromDevice device: Device, willRetry retry: Bool)
    
    /**
     Called when the `Manager` did change state.
     */
    func managerDidUpdateState(state: ManagerState)
    
}


public enum ManagerState : Int {
    case Unknown
    case Resetting
    case Unsupported
    case Unauthorized
    case PoweredOff
    case PoweredOn
}

private struct ManagerConstants {
    static let dispatchQueueLabel = "nl.e-sites.bluetooth-kit"
    static let restoreIdentifier = "nl.e-sites.bluetooth-kit.restoreIdentifier"
    static let UUIDStoreKey = "nl.e-sites.bluetooth-kit.UUID"
}


internal extension CollectionType where Generator.Element == String {
    
    func CBUUIDs() -> [CBUUID] {
        return self.map({ (UUID) -> CBUUID in
            return CBUUID(string: UUID)
        })
    }
    
}
