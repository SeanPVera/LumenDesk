import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - LIFX delegate

extension LightManager: LIFXClientDelegate {
    nonisolated func lifxDiscovered(macHex: String, address: String) {
        Task { @MainActor in
            guard self.demoWorkspaceController.acceptsLiveNetworkCallbacks else { return }
            let id = "lifx:\(macHex)"
            if let existing = self.device(withID: id) {
                self.scanResponseCount += 1
                let oldAddress = existing.address
                existing.address = address
                if oldAddress != address {
                    self.razerActiveIDs.remove(existing.id)
                    self.appendDiscoveryChange(existing, kind: .changed, detail: "Address changed from \(oldAddress) to \(address)")
                }
                self.markSeen(existing)
            } else {
                let device = LightDevice(id: id, brand: .lifx, backendID: macHex,
                                         name: "LIFX \(macHex.suffix(6))", address: address)
                self.upsert(device)
            }
        }
    }

    nonisolated func lifxDidIdentify(macHex: String, vendorID: UInt32, productID: UInt32) {
        Task { @MainActor in
            guard self.demoWorkspaceController.acceptsLiveNetworkCallbacks,
                  vendorID == 1,
                  let device = self.device(withID: "lifx:\(macHex)") else { return }
            device.productID = productID
            if let sku = LIFXProductCatalog.sku(for: productID) {
                device.sku = sku
            }
        }
    }

    nonisolated func lifxDidUpdate(macHex: String, label: String, color: LIFXHSBK, isOn: Bool) {
        Task { @MainActor in
            guard self.demoWorkspaceController.acceptsLiveNetworkCallbacks else { return }
            let id = "lifx:\(macHex)"
            guard let device = self.device(withID: id) else { return }
            if self.isScanning { self.scanResponseCount += 1 }
            if !label.isEmpty && label != device.name {
                device.name = label
                self.sortDevices()
            }
            let h = Double(color.hue) / 65535.0
            let s = Double(color.saturation) / 65535.0
            let reportedColor = Color(hue: h, saturation: s, brightness: 1.0)
            let rgb = reportedColor.rgbComponents
            let brightness = Double(color.brightness) / 65535.0
            let matches = self.reportedStateMatchesExpectation(
                deviceID: id,
                isOn: isOn,
                brightness: brightness,
                red: rgb.r,
                green: rgb.g,
                blue: rgb.b,
                kelvin: Int(color.kelvin)
            )
            if !self.isEffectAnimating(id) && (!self.commandPendingIDs.contains(id) || matches) {
                if device.isOn != isOn { device.isOn = isOn }
                if abs(device.brightness - brightness) > 0.001 { device.brightness = brightness }
                if device.kelvin != Int(color.kelvin) { device.kelvin = Int(color.kelvin) }
                if device.color.rgbDistance(to: reportedColor) > 0.005 { device.color = reportedColor }
            }
            self.markSeen(device, confirmsPendingCommand: matches)
        }
    }

    nonisolated func lifxDidUpdateMatrix(macHex: String, productID: UInt32,
                                         width: Int, height: Int,
                                         colors: [LIFXHSBK]) {
        Task { @MainActor in
            guard self.demoWorkspaceController.acceptsLiveNetworkCallbacks,
                  let device = self.device(withID: "lifx:\(macHex)") else { return }
            if productID != 0 {
                device.productID = productID
                device.sku = LIFXProductCatalog.sku(for: productID) ?? device.sku
            }
            guard device.isLIFXLuna else { return }
            let previous = self.lifxMatrixStates[device.id]
            let matrix = LIFXMatrixState(
                productID: device.productID ?? productID,
                width: width,
                height: height,
                colors: colors.map(LIFXMatrixColor.init),
                isActive: true
            )
            self.lifxMatrixStates[device.id] = matrix
            if previous?.productID != matrix.productID || previous?.width != matrix.width || previous?.height != matrix.height {
                self.musicFixtureCache.removeAll()
                for scope in self.musicModeController.activeScopeIDs
                    where self.effectRuns[scope]?.ownedDeviceIDs.contains(device.id) == true {
                    self.musicModeController.updateFixtures(scope: scope, fixtures: self.musicFixtureDescriptors(in: scope))
                }
            }
            self.markSeen(device)
        }
    }

    nonisolated func lifxCommandFailed(_ error: Error) {
        Task { @MainActor in
            guard self.demoWorkspaceController.acceptsLiveNetworkCallbacks else { return }
            let affected = Set(self.devices.lazy
                .filter { $0.brand == .lifx && self.commandPendingIDs.contains($0.id) }
                .map(\.id))
            self.commandCoordinator.fail(deviceIDs: affected, summary: "LIFX rejected the command")
            self.publishError("LIFX command failed: \(error)")
        }
    }

    nonisolated func lifxDiscoveryProbe(_ report: DiscoveryProbeReport) {
        Task { @MainActor in self.lifxProbe = report }
    }
}

// MARK: - Govee delegate

extension LightManager: GoveeClientDelegate {
    nonisolated func goveeDiscovered(deviceID: String, address: String, sku: String?) {
        Task { @MainActor in
            guard self.demoWorkspaceController.acceptsLiveNetworkCallbacks else { return }
            let id = "govee:\(deviceID)"
            if let existing = self.device(withID: id) {
                self.scanResponseCount += 1
                let oldAddress = existing.address
                existing.address = address
                if let sku, existing.sku != sku { existing.sku = sku }
                if oldAddress != address {
                    // The client now targets a different endpoint. Treat the
                    // volatile stream mode as unknown so it is enabled once
                    // at the new address.
                    self.razerActiveIDs.remove(existing.id)
                    self.appendDiscoveryChange(existing, kind: .changed, detail: "Address changed from \(oldAddress) to \(address)")
                }
                self.markSeen(existing)
                // On app launch the in-memory mode set is empty, so this
                // enables streaming once. Routine discovery responses then
                // refresh only the frame and cannot create an H60B0 flash.
                self.reassertStreamHoldIfNeeded(existing)
            } else {
                let suffix = deviceID.split(separator: ":").suffix(2).joined(separator: "")
                let display = sku.map { "\($0) \(suffix)" } ?? "Govee \(suffix)"
                let device = LightDevice(id: id, brand: .govee, backendID: deviceID,
                                         name: display, address: address, sku: sku)
                self.upsert(device)
                // First sighting after an app launch: restore any held layout.
                self.reassertStreamHoldIfNeeded(device, forceModeEnable: true)
            }
        }
    }

    nonisolated func goveeDidUpdate(deviceID: String, isOn: Bool, brightness: Int,
                                    r: Int, g: Int, b: Int, kelvin: Int) {
        Task { @MainActor in
            guard self.demoWorkspaceController.acceptsLiveNetworkCallbacks else { return }
            let id = "govee:\(deviceID)"
            guard let device = self.device(withID: id) else { return }
            if self.isScanning { self.scanResponseCount += 1 }
            let wasOn = device.isOn
            let normalizedBrightness = Double(min(100, max(0, brightness))) / 100.0
            let red = Double(min(255, max(0, r))) / 255.0
            let green = Double(min(255, max(0, g))) / 255.0
            let blue = Double(min(255, max(0, b))) / 255.0
            let kelvin = kelvin <= 0 ? 0 : min(9000, max(1200, kelvin))
            let matches = self.reportedStateMatchesExpectation(
                deviceID: id,
                isOn: isOn,
                brightness: normalizedBrightness,
                red: red,
                green: green,
                blue: blue,
                kelvin: kelvin
            )
            if !self.isEffectAnimating(id) && (!self.commandPendingIDs.contains(id) || matches) {
                if device.isOn != isOn { device.isOn = isOn }
                if abs(device.brightness - normalizedBrightness) > 0.001 {
                    device.brightness = normalizedBrightness
                }
                if kelvin > 0, device.kelvin != kelvin { device.kelvin = kelvin }
                let reportedColor = Color(red: red, green: green, blue: blue)
                if device.color.rgbDistance(to: reportedColor) > 0.005 { device.color = reportedColor }
            }
            if !isOn {
                // A physical or externally initiated power-off clears razer mode.
                self.razerActiveIDs.remove(id)
            } else if !wasOn {
                self.reassertStreamHoldIfNeeded(device)
            }
            self.markSeen(device, confirmsPendingCommand: matches)
        }
    }

    nonisolated func goveeCommandFailed(deviceID: String, kind: String, error: Error) {
        Task { @MainActor in
            guard self.demoWorkspaceController.acceptsLiveNetworkCallbacks else { return }
            let id = "govee:\(deviceID)"
            // Only the light that actually failed. Failing every pending Govee
            // command on one bad send reported errors for lights that were fine.
            if self.commandPendingIDs.contains(id) {
                self.commandCoordinator.fail(deviceIDs: [id], summary: "Govee light did not accept the command")
            }
            let device = self.device(withID: id)
            let code = (error as? UDPSocket.SocketError)?.errnoCode
            if let code, UDPSocket.isUnoccupied(code) {
                // "No route to host" for a light that was discovered a moment
                // ago means it stopped answering ARP: powered off, asleep, or
                // moved. That is staleness, and the recovery is a rescan — not
                // a raw errno in a toast.
                device?.isStale = true
                guard kind != GoveeClient.backgroundPollKind else { return }
                let name = device?.label ?? "A Govee light"
                self.publishError("\(name) is not answering at \(device?.address ?? "its last address"). It may be powered off or on another network — scan again to find it.")
                return
            }
            // A background status poll should not raise the same alarm as
            // something the user asked for.
            guard kind != GoveeClient.backgroundPollKind else { return }
            self.publishError("Govee command failed: \(error)")
        }
    }

    nonisolated func goveeDiscoveryProbe(_ report: DiscoveryProbeReport) {
        Task { @MainActor in self.goveeProbe = report }
    }
}

