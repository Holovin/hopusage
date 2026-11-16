import Foundation

@MainActor
final class CopilotProvider: ProviderRuntime {
    /// `UserDefaults` key caching the slug of the org whose billing carried Copilot credit usage, so
    /// steady-state refreshes make one billing call instead of re-probing every org. This is the
    /// standard card's key; every card keys it by its own id (`billingOrgKey`).
    static let billingOrgDefaultsKey = "copilot.billingOrg"

    /// Id of the "Copilot (CLI/Desktop)" card, which reads the GitHub Copilot desktop app / `copilot`
    /// CLI login instead of editor and GitHub CLI tokens.
    static let cliProviderID = "copilot-cli"

    static func makeProvider(id: String = "copilot", displayName: String = "Copilot") -> Provider {
        Provider(
            id: id,
            displayName: displayName,
            icon: .providerMark("copilot"),
            links: [
                .init(label: "Status", url: "https://www.githubstatus.com/"),
                .init(label: "Dashboard", url: "https://github.com/settings/billing")
            ]
        )
    }

    /// The "Copilot (CLI/Desktop)" card: same meters as Copilot, token from `~/.copilot` + Keychain.
    static func cli(defaults: UserDefaults = .standard) -> CopilotProvider {
        CopilotProvider(
            provider: makeProvider(id: cliProviderID, displayName: "Copilot (CLI/Desktop)"),
            authStore: CopilotCLIAuthStore(),
            defaults: defaults,
            usageScanner: CopilotCLIUsageScanner()
        )
    }

    let provider: Provider
    let authStore: any CopilotTokenLoading
    let usageClient: CopilotUsageClient
    let orgBillingClient: CopilotOrgBillingClient
    let defaults: UserDefaults
    let now: @Sendable () -> Date
    /// Local usage log of the Copilot desktop app / CLI; only the "Copilot (CLI/Desktop)" card has one.
    let usageScanner: CopilotCLIUsageScanner?

    init(
        provider: Provider = CopilotProvider.makeProvider(),
        authStore: any CopilotTokenLoading = CopilotAuthStore(),
        usageClient: CopilotUsageClient = CopilotUsageClient(),
        orgBillingClient: CopilotOrgBillingClient = CopilotOrgBillingClient(),
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = Date.init,
        usageScanner: CopilotCLIUsageScanner? = nil
    ) {
        self.provider = provider
        self.authStore = authStore
        self.usageClient = usageClient
        self.orgBillingClient = orgBillingClient
        self.defaults = defaults
        self.now = now
        self.usageScanner = usageScanner
    }

    var widgetDescriptors: [WidgetDescriptor] {
        guard usageScanner != nil else { return meterDescriptors }
        // The CLI/Desktop card leads with its everyday rows — Credits, Today, Yesterday, Usage Trend,
        // This Period — then the opt-in meters and Last 30 Days.
        let all = meterDescriptors + usageDescriptors
        let order = ["premium", "today", "yesterday", "trend", "period",
                     "orgCredits", "orgSpend", "chat", "completions", "extra", "last30"]
            .map { "\(provider.id).\($0)" }
        return all.sorted { (order.firstIndex(of: $0.id) ?? .max) < (order.firstIndex(of: $1.id) ?? .max) }
    }

    static let usageSourceNote = "From your GitHub Copilot app and CLI usage log"

    /// Usage Trend, This Period (spend since the billing period began), and the shared Today /
    /// Yesterday / Last 30 Days spend tiles. The dollars are the AI credits Copilot itself recorded, so
    /// they're exact, not estimated.
    private var usageDescriptors: [WidgetDescriptor] {
        [
            .usageTrend(provider: provider)
                .exportingHistory(scope: .machineLocal, estimatedCost: false, sourceNote: Self.usageSourceNote),
            .combined(id: "\(provider.id).period", provider: provider, title: "This Period", isUsagePeriod: true)
        ] + WidgetDescriptor.spendTiles(provider: provider)
    }

    private var meterDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "\(provider.id).premium", provider: provider, title: "Credits")
                .exportingLimit("premiumCredits", unit: "credits", source: .progressOrValue(kind: .count)),
            .values(id: "\(provider.id).extra", provider: provider, title: "Extra Usage", selection: .kind(.count))
                .exportingLimit("extraUsage", unit: "count", source: .value(kind: .count)),
            .values(id: "\(provider.id).orgCredits", provider: provider, title: "Org Credits", selection: .kind(.count))
                .exportingLimit("orgCredits", unit: "credits", source: .value(kind: .count, label: "credits")),
            .values(id: "\(provider.id).orgSpend", provider: provider, title: "Org Spend", selection: .kind(.dollars), valueWord: "spent")
                .exportingLimit("orgSpend", unit: "usd", source: .value(kind: .dollars)),
            .percent(id: "\(provider.id).chat", provider: provider, title: "Chat")
                .exportingLimit("chat", unit: "percent"),
            .percent(id: "\(provider.id).completions", provider: provider, title: "Completions")
                .exportingLimit("completions", unit: "percent")
        ]
    }

    func hasLocalCredentials() async -> Bool {
        // Same source as `refresh()`: this card's token loader.
        await loadOffMainActor { [authStore] in authStore.loadToken() } != nil
    }

    func refresh() async -> ProviderSnapshot {
        let token = await loadOffMainActor { [authStore] in authStore.loadToken() }
        guard let token else {
            return ProviderSnapshot.error(provider: provider, error: authStore.notLoggedInError)
        }

        do {
            let response = try await usageClient.fetchUsage(token: token.value)

            // GitHub sends its rate limits as 403 too; that is a wait, not a rejected token.
            if CopilotUsageMapper.isRateLimit(response) {
                return ProviderSnapshot.error(provider: provider, error: CopilotUsageError.rateLimited)
            }
            if response.statusCode == 401 || response.statusCode == 403 {
                return ProviderSnapshot.error(provider: provider, error: authStore.tokenInvalidError)
            }
            guard (200..<300).contains(response.statusCode) else {
                return ProviderSnapshot.error(provider: provider, error: CopilotUsageError.requestFailed(response.statusCode))
            }

            let mapped = try CopilotUsageMapper.map(response)

            // An org-managed (token-based-billing) seat has no per-seat percent meter, so the real
            // usage lives in the org's billing. Look it up there — best-effort: an org admin sees
            // Org Credits / Org Spend, everyone else keeps the plan-only card as before. Gated on
            // the mapper's explicit flag, never on `lines` being empty (issue #839). Appended rather
            // than replacing: `mapped.lines` can already carry the user's own personal Credits count
            // (issue #1094), which must survive alongside whatever the org lookup adds.
            var lines = mapped.lines
            if mapped.isOrgManagedSeat {
                lines += await orgBillingLines(token: token.value)
            }
            let usage = await appendLocalUsage(to: &lines, creditsResetAt: CopilotUsageMapper.creditsResetAt(mapped.lines))

            return ProviderSnapshot.make(
                provider: provider, plan: mapped.plan, lines: lines, refreshedAt: now(),
                usageHistory: usage.map {
                    ProviderUsageHistory(series: $0.series, modelUsage: $0.modelUsage, unknownModelsByDay: $0.unknownModelsByDay)
                }
            )
        } catch let error as CopilotUsageError {
            return ProviderSnapshot.error(provider: provider, error: error)
        } catch {
            return ProviderSnapshot.error(provider: provider, error: CopilotUsageError.connectionFailed)
        }
    }

    // MARK: - Local usage log

    /// Spend tiles and trend from the desktop app / CLI usage log, returning the scan for the snapshot's
    /// usage history. A failed read only loses the tiles — the live meters still show — and is logged.
    private func appendLocalUsage(to lines: inout [MetricLine], creditsResetAt: Date?) async -> LogUsageScan? {
        guard let usageScanner else { return nil }
        let refreshedAt = now()
        let periodStart = CopilotCLIUsageScanner.periodStart(resetsAt: creditsResetAt, now: refreshedAt)
        let result: CopilotCLIUsageScan?
        do {
            result = try await usageScanner.scan(now: refreshedAt, periodStart: periodStart)
        } catch {
            AppLog.warn(LogTag.plugin(provider.id), "usage log unreadable; showing meters only: \(error.localizedDescription)")
            return nil
        }
        guard let result else { return nil }
        let scan = result.window
        if let period = result.period {
            SpendTileMapper.appendPeriodUsage(
                label: "This Period", period.series, to: &lines,
                estimated: false, modelUsage: period.modelUsage, modelSourceNote: Self.usageSourceNote
            )
        }
        SpendTileMapper.appendTokenUsage(
            scan.series, to: &lines, now: refreshedAt,
            estimated: false,
            unknownModelsByDay: scan.unknownModelsByDay,
            modelUsage: scan.modelUsage,
            modelSourceNote: Self.usageSourceNote
        )
        SpendTileMapper.appendUsageTrend(scan.series, to: &lines, now: refreshedAt, note: Self.usageSourceNote)
        return scan
    }

    // MARK: - Org billing lookup

    /// Per-card cache key for the remembered billing org (`copilot.billingOrg` for the standard card).
    private var billingOrgKey: String { "\(provider.id).billingOrg" }

    /// Org-level Copilot billing lines for an org-managed seat. Tries the cached org first, then probes
    /// every org the user belongs to, remembering the first whose billing summary carries Copilot credit
    /// usage. Returns `[]` when nothing is readable — a 403 is the *expected* outcome for a plain org
    /// member (only owners and billing managers can read org billing), so it degrades to today's
    /// plan-only card instead of erroring the provider.
    private func orgBillingLines(token: String) async -> [MetricLine] {
        if let cached = defaults.string(forKey: billingOrgKey) {
            do {
                if let lines = try await usageLines(org: cached, token: token) {
                    return lines
                }
                // The cached org answered but no longer shows Copilot usage (left the org, lost the
                // billing role, org stopped using Copilot) — forget it and re-probe from scratch.
                defaults.removeObject(forKey: billingOrgKey)
            } catch {
                // Transient failure: log it and keep the cached org for the next refresh.
                AppLog.warn(LogTag.plugin(provider.id), "org billing lookup failed for the remembered org: \(error.localizedDescription)")
                return []
            }
        }

        let orgs: [String]
        do {
            let response = try await orgBillingClient.fetchUserOrgs(token: token)
            guard response.statusCode == 200 else {
                // 403 here means the token lacks `read:org` (editor-plugin tokens can) — expected, not
                // an error. Anything else is still worth a diagnostic, never a failed card.
                AppLog.info(LogTag.plugin(provider.id), "org list HTTP \(response.statusCode); skipping org billing lookup")
                return []
            }
            orgs = CopilotOrgBillingMapper.orgLogins(response)
        } catch {
            AppLog.warn(LogTag.plugin(provider.id), "org list fetch failed: \(error.localizedDescription)")
            return []
        }

        for org in orgs {
            do {
                if let lines = try await usageLines(org: org, token: token) {
                    defaults.set(org, forKey: billingOrgKey)
                    return lines
                }
            } catch {
                // One org's billing having an outage must not hide another org's usage — keep probing.
                AppLog.warn(LogTag.plugin(provider.id), "org billing summary failed for one org; trying the next: \(error.localizedDescription)")
            }
        }
        return []
    }

    /// One org's billing summary → metric lines, or `nil` when this org definitively has nothing to show
    /// (no access — the expected 403 for plain members — or no Copilot credit usage in the summary).
    /// Throws for transient failures (transport errors, 429, 5xx) so callers keep the cached org instead
    /// of treating a brief outage as a stale org.
    private func usageLines(org: String, token: String) async throws -> [MetricLine]? {
        let response = try await orgBillingClient.fetchUsageSummary(org: org, token: token)
        guard response.statusCode == 200 else {
            AppLog.debug(LogTag.plugin(provider.id), "org billing summary for one org: HTTP \(response.statusCode)")
            if response.statusCode == 429 || response.statusCode >= 500 {
                throw CopilotUsageError.requestFailed(response.statusCode)
            }
            return nil
        }
        return CopilotOrgBillingMapper.usageLines(response)
    }
}
