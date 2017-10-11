//
//  Manager.swift
//  Bluetonium
//
//  Created by Dominggus Salampessy on 23/12/15.
//  Copyright © 2015 E-sites. All rights reserved.
//

import Foundation
import CoreBluetooth

open class Manager: NSObject {
    
    open var bluetoothEnabled: Bool {
        return central?.state == .poweredOn
    }
    
    open var isStorred: Bool {
        get {
            return storedConnectedUUID != nil
        }
    }
    
    open var rssiForConnect: Int = -100
    open var stopScanWhenConnecting: Bool = true
    open var shouldConnectAfterDisconnect: Bool = true
    
    open static let shared: Manager = Manager()
    
    private(set) open var scanning = false
    fileprivate(set) open var connectedDevices: [Device] = []
    fileprivate(set) open var referenceForFakeConneced: [Device] = []
    fileprivate(set) open var foundPeripherals: [CBPeripheral] = []
    fileprivate(set) open var foundDevices: [Device] = []
    fileprivate(set) open var willRestoreState: [CBPeripheral]?
    
    open weak var delegate: ManagerDelegate?
    
    private var central: CBCentralManager?
    private var disconnecting = false
    fileprivate lazy var dispatchQueue:DispatchQueue = DispatchQueue(label: ManagerConstants.dispatchQueueLabel, attributes: [])
    
    fileprivate var deviceWTFREFERENCE:CBPeripheral?
    // MARK: Initializers
    
    public init(background: Bool = true) {
        super.init()
        
        let options:[String: String]? = background ? [CBCentralManagerOptionRestoreIdentifierKey: ManagerConstants.restoreIdentifier] : nil
        central = CBCentralManager(delegate: self, queue: dispatchQueue, options: options)
    }
    
    // MARK: Public functions
    
    /**
     Start scanning for devices advertising with a specific service.
     The services can also be nil this will return all found devices.
     Found devices will be returned in the foundDevices array.
     
     - parameter services: The UUID of the service the device is advertising with, can be nil.
     */
    open func scan(with CBUUIDs: [String]? = nil, allowDuplicates: Bool = false) {
        //        if scanning == true {
        //            return
        //        }
        scanning = true
        
        foundDevices.removeAll()
        foundPeripherals.removeAll()
        central?.scanForPeripherals(withServices: CBUUIDs?.cbUuids, options: [CBCentralManagerScanOptionAllowDuplicatesKey: allowDuplicates])
    }
    
    /**
     Stop scanning for devices.
     Only possible when it's scanning.
     */
    open func stop() {
        scanning = false
        
        central?.stopScan()
    }
    
    /**
     Connect with a device. This device is returned from the foundDevices list.
     
     - parameter device: The device to connect with.
     */
    open func connect(with device: Device) {
        foundDevices.append(device)
        foundPeripherals.append(device.peripheral)
        
        // Store connected UUID, to enable later connection to the same peripheral.
        store(connectedUUID: device.peripheral.identifier.uuidString)
        
        //        guard device.peripheral.state == .disconnected else {
        //            return
        //        }
        
        DispatchQueue.main.async {
            // Send callback to delegate.
            self.delegate?.manager(self, willConnectToDevice: device)
        }
        
        log("try connect to: \(device)")
        connect(to: device.peripheral)
    }
    
    /**
     Disconnect from the connected device.
     Only possible when not connected to a device.
     */
    open func disconnect(from device: Device) {
        // Reset stored UUID.
        //        store(connectedUUID: nil)
        guard let connectedDeviceIndex = connectedDevices.index(of: device) else {
            return
        }
        connectedDevices.remove(at: connectedDeviceIndex)
        
        guard let foundDevicesIndex = foundDevices.index(of: device) else {
            return
        }
        foundDevices.remove(at: foundDevicesIndex)
        foundPeripherals.remove(at: foundDevicesIndex)
        
        removeConnectedUUID(uuid: device.peripheral.identifier.uuidString)
        
        let peripheral = device.peripheral
        
        disconnecting = true
        central?.cancelPeripheralConnection(peripheral)
    }
    
    private func removeConnectedUUID(uuid: String) {
        
        var array = storedConnectedUUID
        guard let index = array?.index(of: uuid) else {
            return
        }
        array?.remove(at: index)
        
        let defaults = UserDefaults.standard
        defaults.set(array, forKey: ManagerConstants.UUIDStoreKey)
        defaults.synchronize()
        
    }
    
    // MARK: Private functions
    
    fileprivate func connect(to peripheral: CBPeripheral) {
        if stopScanWhenConnecting {
            stop()
        }
        deviceWTFREFERENCE = peripheral
        central?.connect(peripheral, options: [ CBConnectPeripheralOptionNotifyOnDisconnectionKey: NSNumber(value: true) ])
    }
    
    /**
     Store the connectedUUID in the UserDefaults.
     This is to restore the connection after the app restarts or runs in the background.
     */
    fileprivate func store(connectedUUID uuid: String?) {
        
        //reuse or init
        var array = storedConnectedUUID ?? [String]()
        log("storred uuid's: \(array)")
        
        guard let _uuid = uuid, !array.contains(_uuid) else {
            log("array contains this uuid: \(String(describing: uuid))")
            return
        }
        
        //append new value
        array.append(_uuid)
        log("append uuid: \(_uuid) to array")
        
        let defaults = UserDefaults.standard
        defaults.set(array, forKey: ManagerConstants.UUIDStoreKey)
        defaults.synchronize()
    }
    
    /**
     Returns the stored UUID if there is one.
     */
    open var storedConnectedUUID:[String]? {
        return UserDefaults.standard.array(forKey: ManagerConstants.UUIDStoreKey) as? [String]
    }
    
    fileprivate func log(_ log: String) {
        DispatchQueue.main.async {
            self.delegate?.manager(self, didLog: log)
        }
    }
    
    // MARK: CBCentralManagerDelegate
}

extension Manager: CBCentralManagerDelegate {
    
    public func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        log("\(Date()) willRestoreState: \(String(describing: dict[CBCentralManagerRestoredStatePeripheralsKey]))")
        
        willRestoreState = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral]
        
        DispatchQueue.main.async {
            self.delegate?.manager(self, willRestoreState: dict)
        }
        
    }
    
    
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        
        switch central.state {
        case .poweredOn:
            
            willRestoreState?.forEach({ (peripheral) in
                let device = Device(peripheral: peripheral)
                self.connect(with: device)
            })
            
            connectedDevices.forEach({ (device) in
                self.connect(to: device.peripheral)
            })
            
            log("storred uuids \(String(describing: storedConnectedUUID))")
            
            storedConnectedUUID?.forEach({ (uuid) in
                log("storred uuid: \(uuid)")
                guard let uuid = UUID(uuidString: uuid) else {
                    return
                }
                let peripherals = central.retrievePeripherals(withIdentifiers: [uuid])
                log("storred periphreals \(peripherals)")
                peripherals.forEach({ (peripheral) in
                    log("storred periphreal \(peripheral) and try connect to it")
                    //dispatchQueue.asyncAfter(deadline: DispatchTime.now() + Double(Int64(0.2 * Double(NSEC_PER_SEC))) / Double(NSEC_PER_SEC)) { [weak self] in
                    deviceWTFREFERENCE = peripheral
                    if let _peripheral = deviceWTFREFERENCE {
                        let device = Device(peripheral: _peripheral)
                        self.referenceForFakeConneced.append(device)
                        self.connect(with: device)
                    }
                    //}
                })
            })
            
        case .poweredOff:
            //            DispatchQueue.main.async {
            //                self.connectedDevices.forEach({ (device) in
            //                    device.serviceModelManager.resetServices()
            //                    self.delegate?.manager(self, disconnectedFromDevice: device, willRetry: false)
            //                })
            //            }
            break
        default:
            break
        }
        
        DispatchQueue.main.async {
            self.delegate?.managerDidUpdateState(state: ManagerState(rawValue: central.state.rawValue) ?? .unknown)
        }
        
    }
    
    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        
        DispatchQueue.main.async {
            self.delegate?.manager(self, didDiscover: peripheral.name ?? "nil", advertisementData: advertisementData, rssi: RSSI)
        }
        
        guard RSSI.intValue > self.rssiForConnect else {
            return
        }
        
        let name = advertisementData["kCBAdvDataLocalName"] as? String
        
        let device = Device(peripheral: peripheral, with: name)
        
        guard let _delegate = delegate, _delegate.manager(self, shouldConnectTo: device, advertisementData: advertisementData) else {
            //это вообще бесплоезно, знаю, но чисто для теста одного бага на который мы потратили уже 3 месяца
            return
        }
        
        // Only after adding it to the list to prevent issues reregistering the delegate.
        device.registerServiceManager()
        
        DispatchQueue.main.async {
            self.delegate?.manager(self, didFindDevice: device)
            self.delegate?.manager(self, didFindDevice: device, rssi: RSSI)
        }
        
        connect(with: device)
    }
    
    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        
        DispatchQueue.main.async {
            self.delegate?.manager(self, didConnect: peripheral.name ?? "nil")
        }
        
        //monkeycode here
        //быдлокод ввиду криво спроектированного класа
        let index = foundDevices.index(where: { $0.peripheral == peripheral })
        var device = Device(peripheral: peripheral)
        
        if let _index = index {
            device = foundDevices[_index]
        }
        
        // Only after adding it to the list to prevent issues reregistering the delegate.
        device.registerServiceManager()
        
        let contains = connectedDevices.contains {
            $0.peripheral.identifier == device.peripheral.identifier && device.name == $0.name
        }
        
        if !contains {
            connectedDevices.append(device)
            log("append to connectedDevices: \(device)")
        } else {
            referenceForFakeConneced.append(device)
            
            log("device \(device) already connected, don't add it to array")
        }
        
        DispatchQueue.main.async {
            // Send callback to delegate.
            self.delegate?.manager(self, connectedToDevice: device)
            
            // Start discovering services process after connecting to peripheral.
            device.serviceModelManager.discoverRegisteredServices()
        }
    }
    
    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        
        DispatchQueue.main.async {
            self.delegate?.manager(self, didFailToConnect: peripheral.name ?? "nil", error: error)
        }
        
        connect(to: peripheral)
    }
    
    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        DispatchQueue.main.async {
            self.delegate?.manager(self, didDisconnectPeripheral: peripheral.name ?? "nil", error: error)
        }
        
        let connectedPeripherals = connectedDevices.map { (device) -> CBPeripheral in
            return device.peripheral
        }
        
        var _index: Int? = nil //setup by default
        var connectedDevice = Device(peripheral: peripheral) //setup by default
        if let index = connectedPeripherals.index(of: peripheral) {
            connectedDevice = connectedDevices[index]
            //            connectedDevice.serviceModelManager.resetServices()
            _index = index
        }
        
        DispatchQueue.main.async {
            self.delegate?.manager(self, disconnectedFromDevice: connectedDevice, willRetry: true)
        }
        
        // Send reconnect command after peripheral disconnected.
        // It will connect again when it became available.
        if shouldConnectAfterDisconnect {
            connect(with: connectedDevice)
        }
        
        //remove from connected
        if let index = _index {
            connectedDevices.remove(at: index)
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

