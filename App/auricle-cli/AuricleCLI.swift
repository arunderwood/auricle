import ArgumentParser

@main
struct AuricleCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "auricle",
        abstract: "Personal meeting notes pipeline",
        subcommands: [
            RecordVerb.self,
            StopVerb.self,
            DiscardVerb.self,
            RunVerb.self,
            AttributeVerb.self,
            KeepVerb.self,
            ListVerb.self,
            StatusVerb.self,
            ConfigVerb.self,
            DoctorVerb.self,
            BareInvocation.self,
            InternalStageWorker.self,
            StrategyComparisonVerb.self,
            JargonWedgeVerb.self,
        ],
        defaultSubcommand: BareInvocation.self,
    )
}
