import AVFoundation
import MediaPlayer
import SwiftUI
import UIKit

/// Suppresses the system volume HUD and turns hardware Volume Up / Volume Down presses into page turns
/// when enabled inside the sideloaded reader. Preserves background music via `.ambient` + `.mixWithOthers`.
struct VolumePageTurnBridge: UIViewRepresentable {
    var enabled: Bool
    var onVolumeNext: () -> Void
    var onVolumePrev: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let container = UIView(frame: CGRect(x: -2000, y: -2000, width: 1, height: 1))
        container.clipsToBounds = true
        container.isUserInteractionEnabled = false
        context.coordinator.attachVolumeView(into: container)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onVolumeNext = onVolumeNext
        context.coordinator.onVolumePrev = onVolumePrev
        context.coordinator.setEnabled(enabled)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.setEnabled(false)
    }

    final class Coordinator: NSObject {
        var onVolumeNext: (() -> Void)?
        var onVolumePrev: (() -> Void)?

        private var volumeView: MPVolumeView?
        private var observation: NSKeyValueObservation?
        private var isEnabled = false
        private var ignoreUntilTime: CFTimeInterval = 0
        private var baselineVolume: Float = 0.5

        override init() {
            super.init()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(appDidBecomeActive),
                name: UIApplication.didBecomeActiveNotification,
                object: nil
            )
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
            stopObserving()
        }

        func attachVolumeView(into host: UIView) {
            let vv = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 100, height: 40))
            vv.alpha = 0.0001
            vv.isUserInteractionEnabled = false
            host.addSubview(vv)
            self.volumeView = vv
        }

        func setEnabled(_ enabled: Bool) {
            guard enabled != isEnabled else { return }
            isEnabled = enabled
            if enabled {
                startObserving()
            } else {
                stopObserving()
            }
        }

        @objc private func appDidBecomeActive() {
            if isEnabled {
                stopObserving()
                startObserving()
            }
        }

        private func startObserving() {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.ambient, options: [.mixWithOthers])
            try? session.setActive(true)

            let current = session.outputVolume
            if current <= 0.06 || current >= 0.94 {
                setSystemVolume(0.5)
                baselineVolume = 0.5
            } else {
                baselineVolume = current
            }
            ignoreUntilTime = CACurrentMediaTime() + 0.25

            observation = session.observe(\.outputVolume, options: [.old, .new]) { [weak self] _, change in
                guard let self, self.isEnabled else { return }
                let now = CACurrentMediaTime()
                guard now > self.ignoreUntilTime else { return }
                guard let newVal = change.newValue else { return }
                let oldVal = change.oldValue ?? self.baselineVolume
                let delta = newVal - oldVal
                guard abs(delta) > 0.001 else { return }

                DispatchQueue.main.async {
                    if delta < 0 {
                        self.onVolumeNext?()
                    } else {
                        self.onVolumePrev?()
                    }
                    self.setSystemVolume(self.baselineVolume)
                }
            }
        }

        private func stopObserving() {
            observation?.invalidate()
            observation = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }

        private func setSystemVolume(_ value: Float) {
            ignoreUntilTime = CACurrentMediaTime() + 0.22
            guard let slider = volumeView?.subviews.compactMap({ $0 as? UISlider }).first else { return }
            slider.setValue(min(0.92, max(0.08, value)), animated: false)
            slider.sendActions(for: .valueChanged)
        }
    }
}
