#if os(macOS)
import SwiftUI

struct ContentView: View {
    @State private var honestCount = 0
    @State private var toggleOn = false
    @State private var keystrokeEcho = ""

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

                HStack(alignment: .top, spacing: 16) {
                    RowListPane()
                    ScrollProbePane()
                    webCard
                }
            }
            .padding(20)
        }
    }

    // Honest, liar, and disabled buttons side by side.
    private var buttonsCard: some View {
        Card(title: "Buttons") {
            Button("Honest Button") { honestCount += 1 }
                .accessibilityLabel("honest-button")
            StatusReadout(name: "counter", value: String(honestCount))

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
            Toggle("Toggle Box", isOn: $toggleOn)
                .accessibilityLabel("toggle-box")
            StatusReadout(name: "toggle-state", value: toggleOn ? "on" : "off")
        }
    }

    // Custom keystroke input (not AX-settable) + independent echo readout.
    private var keystrokeCard: some View {
        Card(title: "Keystroke Input") {
            Text("AX value is read-only; type_text must use CGEvent fallback.")
                .font(.caption)
                .foregroundStyle(.secondary)
            KeystrokeInput(echo: $keystrokeEcho)
                .frame(width: 260, height: 30)
            StatusReadout(name: "keystroke-echo", value: keystrokeEcho.isEmpty ? "empty" : keystrokeEcho)
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
}
#endif
