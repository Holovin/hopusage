import SwiftUI

/// Fork: one Codex card's API Usage settings in Customize, under its OpenAI Admin Key — the day the
/// usage period starts and how often the row fetches. Both are stored per card.
struct CodexAPIUsageSection: View {
    let providerID: String

    @Environment(WidgetDataStore.self) private var dataStore
    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular
    @AppStorage private var periodStartDay: Int
    @AppStorage private var refreshInterval: APIProviderRefreshSetting

    init(providerID: String) {
        self.providerID = providerID
        _periodStartDay = AppStorage(wrappedValue: OpenAIAPIPeriodSetting.fallback,
                                     OpenAIAPIPeriodSetting.key(cardID: providerID))
        _refreshInterval = AppStorage(wrappedValue: APIProviderRefreshSetting.fallback,
                                      APIProviderRefreshSetting.key(cardID: providerID))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            Text("API Usage")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            VStack(alignment: .leading, spacing: 0) {
                row("Period Starts On") {
                    picker($periodStartDay, options: OpenAIAPIPeriodSetting.days) { "Day \($0)" }
                }
                row("Refresh Every") {
                    picker($refreshInterval, options: APIProviderRefreshSetting.allCases, label: \.label)
                }
                Text("Spend counts from this day each month, e.g. when the credit grant renews. OpenAI reports it daily, so it's fetched at most once per interval.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
            .cardSurface()
        }
        .onChange(of: periodStartDay) {
            // The shown row covers the old period; fetch the new one right away.
            dataStore.clearFailureBackoff(for: providerID)
            Task { await dataStore.refresh(providerID: providerID, force: true) }
        }
    }

    private func row(_ label: String, @ViewBuilder control: () -> some View) -> some View {
        HStack(spacing: 10) {
            Text(label)
            Spacer(minLength: 8)
            control()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, density.controlRowPadding)
    }

    private func picker<Value: Hashable>(
        _ selection: Binding<Value>,
        options: [Value],
        label: @escaping (Value) -> String
    ) -> some View {
        Picker("", selection: selection) {
            ForEach(options, id: \.self) { option in
                Text(label(option)).tag(option)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
    }
}
