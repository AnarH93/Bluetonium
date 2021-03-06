//
//  ManagerDelegate.swift
//  Bluetonium
//
//  Created by Bas van Kuijck on 20/03/2017.
//  Copyright © 2017 E-sites. All rights reserved.
//

import Foundation

public protocol ManagerDelegate: class {
    
    func manager(_ manager: Manager, shouldConnectTo peripheral: Device, advertisementData: [String : Any]) -> Bool
    /**
     Called when the `Manager` did find a peripheral and did add it to the foundDevices array.
     */
    func manager(_ manager: Manager, didFindDevice device: Device)
    
    /**
     Called when the `Manager` did find a peripheral and did add it to the foundDevices array.
     */
    func manager(_ manager: Manager, didFindDevice device: Device, rssi RSSI: NSNumber)
    
    /**
     Called when the `Manager` is trying to connect to device
     */
    func manager(_ manager: Manager, willConnectToDevice device: Device)
    
    /**
     Called when the `Manager` did connect to the device.
     */
    func manager(_ manager: Manager, connectedToDevice device: Device)
    
    /**
     Called when the `Manager` did disconnect from the device.
     Retry will indicate if the Manager will retry to connect when it becomes available.
     */
    func manager(_ manager: Manager, disconnectedFromDevice device: Device, willRetry retry: Bool)
    
    /**
     Called when the `Manager` did change state.
     */
    func managerDidUpdateState(state: ManagerState)
    
    
    //debug methods
    func manager(_ manager: Manager, willRestoreState dict: [String : Any])
    func manager(_ manager: Manager, didDiscover peripheralName: String, advertisementData: [String : Any], rssi RSSI: NSNumber)
    func manager(_ manager: Manager, didConnect peripheralName: String)
    func manager(_ manager: Manager, didFailToConnect peripheralName: String, error: Error?)
    func manager(_ manager: Manager, didDisconnectPeripheral peripheralName: String, error: Error?)
    func manager(_ manager: Manager, didLog: String)
}
