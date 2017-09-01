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
    
    open static let shared: Manager = Manager()
    
    private(set) open var scanning = false
    fileprivate(set) open var connectedDevices: [Device] = []
    fileprivate(set) open var foundPeripherals: [CBPeripheral] = []
    fileprivate(set) open var foundDevices: [Device] = []
    fileprivate(set) open var willRestoreState: [CBPeripheral]?
    
    open weak var delegate: ManagerDelegate?
    
    private var central: CBCentralManager?
    private var disconnecting = false
    fileprivate lazy var dispatchQueue:DispatchQueue = DispatchQueue(label: ManagerConstants.dispatchQueueLabel, attributes: [])
    
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
        
        NSLog("try connect to: \(device)")
        connect(to: device.peripheral)
    }
    
    /**
     Disconnect from the connected device.
     Only possible when not connected to a device.
     */
    open func disconnect(from device: Device) {
        // Reset stored UUID.
        store(connectedUUID: nil)
        
        let peripheral = device.peripheral
        
        if peripheral.state != .connected {
            //connectedDevice = nil
        } else {
            disconnecting = true
            central?.cancelPeripheralConnection(peripheral)
        }
    }
    
    // MARK: Private functions
    
    fileprivate func connect(to peripheral: CBPeripheral) {
        if stopScanWhenConnecting {
            stop()
        }
        central?.connect(peripheral, options: [ CBConnectPeripheralOptionNotifyOnDisconnectionKey: NSNumber(value: true) ])
    }
    
    /**
     Store the connectedUUID in the UserDefaults.
     This is to restore the connection after the app restarts or runs in the background.
     */
    fileprivate func store(connectedUUID uuid: String?) {
        
        //reuse or init
        var array = storedConnectedUUID != nil ? storedConnectedUUID! : [String]()
        
        guard let _uuid = uuid, array.contains(_uuid) else {
            return
        }
        
        //append new value
        array.append(_uuid)
        
        let defaults = UserDefaults.standard
        defaults.set(array, forKey: ManagerConstants.UUIDStoreKey)
        defaults.synchronize()
    }
    
    /**
     Returns the stored UUID if there is one.
     */
    fileprivate var storedConnectedUUID:[String]? {
        return UserDefaults.standard.array(forKey: ManagerConstants.UUIDStoreKey) as? [String]
    }
    
    // MARK: CBCentralManagerDelegate
}

extension Manager: CBCentralManagerDelegate {
    
    public func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        NSLog("willRestoreState: \(String(describing: dict[CBCentralManagerRestoredStatePeripheralsKey]))")
        
        willRestoreState = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral]
        
        DispatchQueue.main.async {
            self.delegate?.manager(self, willRestoreState: dict)
        }
        
    }
    
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        
        switch (central.state) {
        case .poweredOn:
            
            willRestoreState?.forEach({ (peripheral) in
                let device = Device(peripheral: peripheral)
                device.registerServiceManager()
                self.connect(with: device)
            })
            
            connectedDevices.forEach({ (device) in
                central.connect(device.peripheral, options: [ CBConnectPeripheralOptionNotifyOnDisconnectionKey: NSNumber(value: true) ])
            })
            
            storedConnectedUUID?.forEach({ (uuid) in
                guard let uuid = UUID(uuidString: uuid) else {
                    return
                }
                let peripherals = central.retrievePeripherals(withIdentifiers: [uuid])
                peripherals.forEach({ (peripheral) in
                    
                    dispatchQueue.asyncAfter(deadline: DispatchTime.now() + Double(Int64(0.2 * Double(NSEC_PER_SEC))) / Double(NSEC_PER_SEC)) { [weak self] in
                        let device = Device(peripheral: peripheral)
                        
                        device.registerServiceManager()
                        self?.connect(with: device)
                    }
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
        
        //быдлокод ввиду криво спроектированного класа
        let index = foundDevices.index(where: { $0.peripheral == peripheral })
        var device = Device(peripheral: peripheral)
        
        if let _index = index {
            device = foundDevices[_index]
        } else {
            // Only after adding it to the list to prevent issues reregistering the delegate.
            device.registerServiceManager()
        }
        
        connectedDevices.append(device)
        
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
            connectedDevice.serviceModelManager.resetServices()
            _index = index
        }
        
        DispatchQueue.main.async {
            self.delegate?.manager(self, disconnectedFromDevice: connectedDevice, willRetry: true)
        }
        
        // Send reconnect command after peripheral disconnected.
        // It will connect again when it became available.
        
        connect(with: connectedDevice)
        
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
