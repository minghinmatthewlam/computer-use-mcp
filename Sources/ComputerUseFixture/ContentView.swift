import SwiftUI

struct ContentView: View {
    @State private var fixtureState = BasicControlsFixtureState.initial
    private let stateStore = BasicControlsFixtureStateStore()
    private let showsStressPanels =
        ProcessInfo.processInfo.environment["COMPUTER_USE_FIXTURE_SMALL_TREE"] != "1"

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 16) {
                Text("ComputerUse Fixture")
                    .font(.title2)
                    .accessibilityLabel("fixture-title")

                HStack(alignment: .top, spacing: 16) {
                    buttonsCard
                    stateCard
                    keystrokeCard
                }

                if showsStressPanels {
                    HStack(alignment: .top, spacing: 16) {
                        RowListPane()
                        ScrollProbePane()
                        webCard
                    }
                }
            }
            .padding(20)
        }
    }

    // Honest, liar, and disabled buttons side by side.
    private var buttonsCard: some View {
        Card(title: "Buttons") {
            Button("Honest Button") {
                updateState { $0.honestCounter += 1 }
            }
                .accessibilityLabel("honest-button")
            StatusReadout(name: "counter", value: String(fixtureState.honestCounter))

            LiarButton()
                .frame(width: 140, height: 30)
            // This readout is wired to NOTHING — the liar mutates no state, so
            // it stays "never-changes" no matter how many times AXPress "wins".
            StatusReadout(name: "liar-readout", value: "never-changes")

            Button("Disabled Button") {}
                .disabled(true)
                .accessibilityLabel("disabled-button")
        }
    }

    // Toggle with a visible on/off state readout.
    private var stateCard: some View {
        Card(title: "State Controls") {
            Toggle(
                "Toggle Box",
                isOn: Binding(
                    get: { fixtureState.toggleOn },
                    set: { value in updateState { $0.toggleOn = value } }
                )
            )
                .accessibilityLabel("toggle-box")
            StatusReadout(name: "toggle-state", value: fixtureState.toggleOn ? "on" : "off")
        }
    }

    // Custom keystroke input (not AX-settable) + independent echo readout.
    private var keystrokeCard: some View {
        Card(title: "Keystroke Input") {
            Text("AX value is read-only; type_text must use CGEvent fallback.")
                .font(.caption)
                .foregroundStyle(.secondary)
            KeystrokeInput(
                echo: Binding(
                    get: { fixtureState.keystrokeEcho },
                    set: { value in updateState { $0.keystrokeEcho = value } }
                )
            )
                .frame(width: 260, height: 30)
            StatusReadout(
                name: "keystroke-echo",
                value: fixtureState.keystrokeEcho.isEmpty ? "empty" : fixtureState.keystrokeEcho
            )
        }
    }

    private var webCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Web Pane (WKWebView)").font(.headline)
            WebPane()
                .frame(width: 420, height: 300)
                .border(Color.gray.opacity(0.3))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.08)))
    }

    private func updateState(_ mutation: (inout BasicControlsFixtureState) -> Void) {
        mutation(&fixtureState)
        do {
            try stateStore.write(fixtureState)
        } catch {
            fputs("ComputerUseFixture state write failed: \(error)\n", stderr)
        }
    }
}
