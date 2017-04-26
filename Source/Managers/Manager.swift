//
//  Manager.swift
//  Bluetonium
//
//  Created by Dominggus Salampessy on 23/12/15.
//  Copyright © 2015 E-sites. All rights reserved.
//

import Foundation
import CoreBluetooth

open class Manager: NSObject, CBCentralManagerDelegate {
    
    open var bluetoothEnabled: Bool {
        return centralManager?.state == .poweredOn
    }

    open var isStorred: Bool {
        get {
            return storedConnectedUUID() != nil
        }
    }

    private(set) open var scanning = false
    private(set) open var connectedDevice: Device?
    private(set) open var foundDevices: [Device]!
    open weak var delegate: ManagerDelegate?
    
    private var centralManager: CBCentralManager?
    private var disconnecting = false
    private lazy var dispatchQueue:DispatchQueue = DispatchQueue(label: ManagerConstants.dispatchQueueLabel, attributes: [])
    
    // MARK: Initializers
    
    public init(background: Bool = false) {
        super.init()
        
        let options:[String: String]? = background ? [CBCentralManagerOptionRestoreIdentifierKey: ManagerConstants.restoreIdentifier] : nil
        foundDevices = []
        centralManager = CBCentralManager(delegate: self, queue: dispatchQueue, options: options)
    }
    
    // MARK: Public functions
    
    /**
     Start scanning for devices advertising with a specific service.
     The services can also be nil this will return all found devices.
     Found devices will be returned in the foundDevices array.
     
     - parameter services: The UUID of the service the device is advertising with, can be nil.
     */
    open func startScanForDevices(advertisingWithServices services: [String]? = nil) {
        if scanning == true {
            return
        }
        scanning = true
        
        foundDevices.removeAll()
        centralManager?.scanForPeripherals(withServices: services?.cbUuids, options: nil)
    }
    
    /**
     Stop scanning for devices.
     Only possible when it's scanning.
     */
    open func stopScanForDevices() {
        scanning = false
        
        centralManager?.stopScan()
    }
    
    /**
     Connect with a device. This device is returned from the foundDevices list.
     
     - parameter device: The device to connect with.
     */
    open func connect(with device: Device) {
        // Only allow connecting when it's not yet connected to another device.
        if connectedDevice != nil || disconnecting {
            return
        }
        
        connectedDevice = device
        connectToDevice()
    }
    
    /**
     Disconnect from the connected device.
     Only possible when not connected to a device.
     */
    open func disconnectFromDevice() {
        // Reset stored UUID.
        store(connectedUUID: nil)
        
        guard let peripheral = connectedDevice?.peripheral else {
            return
        }
        
        if peripheral.state != .connected {
            connectedDevice = nil
        } else {
            disconnecting = true
            centralManager?.cancelPeripheralConnection(peripheral)
        }
    }
    
    // MARK: Private functions
    
    fileprivate func connectToDevice() {
        guard let peripheral = connectedDevice?.peripheral else {
            return
        }
        // Store connected UUID, to enable later connection to the same peripheral.
        store(connectedUUID: peripheral.identifier.uuidString)
        
        guard peripheral.state == .disconnected else {
            return
        }
        
        DispatchQueue.main.async {
            // Send callback to delegate.
            self.delegate?.manager(self, willConnectToDevice: self.connectedDevice!)
        }
        
        centralManager?.connect(peripheral, options: [ CBConnectPeripheralOptionNotifyOnDisconnectionKey: NSNumber(value: true) ])
    }
    
    /**
     Store the connectedUUID in the UserDefaults.
     This is to restore the connection after the app restarts or runs in the background.
     */
    fileprivate func store(connectedUUID uuid: String?) {
        let defaults = UserDefaults.standard
        defaults.set(uuid, forKey: ManagerConstants.UUIDStoreKey)
        defaults.synchronize()
    }
    
    /**
     Returns the stored UUID if there is one.
     */
    fileprivate var storedConnectedUUID:String? {
        return UserDefaults.standard.object(forKey: ManagerConstants.UUIDStoreKey) as? String
    }
    
    // MARK: CBCentralManagerDelegate
    
    @objc public func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        print("willRestoreState: \(dict[CBCentralManagerRestoredStatePeripheralsKey])")
    }
    
    @objc public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        
        switch (central.state) {
        case .poweredOn:
            
            if connectedDevice != nil {
                connectToDevice()
                
            } else if let storedUUID = storedConnectedUUID {
                guard let uuid = UUID(uuidString: storedUUID), let peripheral = central.retrievePeripherals(withIdentifiers: [ uuid ]).first else {
                    return
                }
                
                dispatchQueue.asyncAfter(deadline: DispatchTime.now() + Double(Int64(0.2 * Double(NSEC_PER_SEC))) / Double(NSEC_PER_SEC)) { [weak self] in
                    let device = Device(peripheral: peripheral)
                    device.registerServiceManager()
                    self?.connect(with: device)
                }
            }
            
        case .poweredOff:
            
            DispatchQueue.main.async {
                self.connectedDevice?.serviceModelManager.resetServices()
                
                if let connectedDevice = self.connectedDevice {
                    self.delegate?.manager(self, disconnectedFromDevice: connectedDevice, willRetry: true)
                }
            }
        default:
            break
        }

        dispatch_async(dispatch_get_main_queue()) { () -> Void in
            self.delegate?.managerDidUpdateState(ManagerState(rawValue: central.state.rawValue)!)
        }
    }
    
    @objc public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        let device = Device(peripheral: peripheral)
        if foundDevices.contains(device) {
            return
        }
        
        foundDevices.append(device)
        
        // Only after adding it to the list to prevent issues reregistering the delegate.
        device.registerServiceManager()
        
        DispatchQueue.main.async {
            self.delegate?.manager(self, didFindDevice: device)
            self.delegate?.manager(self, didFindDevice: device, rssi: RSSI)
        }
    }
    
    @objc public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard let connectedDevice = connectedDevice else {
            return
        }
        
        DispatchQueue.main.async {
            // Send callback to delegate.
            self.delegate?.manager(self, connectedToDevice: connectedDevice)
            
            // Start discovering services process after connecting to peripheral.
            connectedDevice.serviceModelManager.discoverRegisteredServices()
        }
    }
    
    @objc public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        print("didFailToConnect \(peripheral)")
    }
    
    @objc public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral.identifier.uuidString == connectedDevice?.peripheral.identifier.uuidString else {
            return
        }
        
        let device = connectedDevice!
        device.serviceModelManager.resetServices()
        
        if disconnecting {
            // Disconnect initated by user.
            connectedDevice = nil
            disconnecting = false
        } else {
            // Send reconnect command after peripheral disconnected.
            // It will connect again when it became available.
            central.connect(peripheral, options: nil)
        }
        
        DispatchQueue.main.async {
            self.delegate?.manager(self, disconnectedFromDevice: device, willRetry: self.connectedDevice != nil)
        }
    }
}

public enum ManagerState : Int {
    case unknown
    case resetting
    case unsupported
    case unauthorized
    case poweredOff
    case poweredOn
}

private struct ManagerConstants {
    static let dispatchQueueLabel = "nl.e-sites.bluetooth-kit"
    static let restoreIdentifier = "nl.e-sites.bluetooth-kit.restoreIdentifier"
    static let UUIDStoreKey = "nl.e-sites.bluetooth-kit.UUID"
}


extension Collection where Iterator.Element:MapValue, Iterator.Element == String {
    var cbUuids:[CBUUID] {
        return self.map { CBUUID(string: $0) }
    }
}
