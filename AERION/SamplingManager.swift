import Foundation
import Observation

@MainActor
@Observable
final class SamplingManager {
    private(set) var metrics = Metrics()

    @ObservationIgnored private let provider: MetricsProvider
    @ObservationIgnored private let worker = DispatchQueue(label: "aerion.sampling", qos: .utility)
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var cadence: TimeInterval?
    @ObservationIgnored private var inFlight = false
    @ObservationIgnored private var powerRefreshPending = false
    @ObservationIgnored private var generation = 0

    init(provider: MetricsProvider) {
        self.provider = provider
    }

    func configure(interval: TimeInterval, visible: Bool, sleeping: Bool) {
        let target = sleeping ? nil : visible ? interval : 30
        guard cadence != target else { return }
        generation += 1
        cadence = target
        timer?.invalidate()
        timer = nil
        guard let target else {
            worker.async { [provider] in provider.resetBaselines() }
            powerRefreshPending = false
            metrics = Metrics()
            return
        }
        if target != 30 {
            worker.async { [provider] in provider.resetBaselines() }
            sample()
        }
        let timer = Timer(timeInterval: target, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        timer.tolerance = target * 0.15
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func powerSourceDidChange() {
        guard cadence != nil else { return }
        if inFlight { powerRefreshPending = true }
        else { sample() }
    }

    private func sample() {
        guard !inFlight, cadence != nil else { return }
        inFlight = true
        let requestedGeneration = generation
        worker.async { [provider, weak self] in
            let reading = provider.sample()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.inFlight = false
                let current = self.generation == requestedGeneration
                if current && self.metrics != reading { self.metrics = reading }
                if self.powerRefreshPending || (!current && self.cadence != 30) {
                    self.powerRefreshPending = false
                    self.sample()
                }
            }
        }
    }
}
