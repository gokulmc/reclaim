import ArgumentParser

@main
struct ReclaimCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reclaim-cli",
        abstract: "Reclaim disk space Docker/Colima quietly ate — and actually give it back to macOS.",
        discussion: """
        Docker on macOS runs inside a Linux VM backed by a sparse disk image. Pruning frees
        blocks inside the VM, but the sparse image on your Mac doesn't shrink until an
        `fstrim` runs. Reclaim runs both steps and reports the real host disk delta.

        Volumes are always read-only in this tool — there is no code path that can ever
        delete one.
        """,
        version: "0.1.0 (M0)",
        subcommands: [
            StatusCommand.self,
            CleanCommand.self,
            TrimCommand.self,
            VolumesCommand.self,
            HistoryCommand.self
        ],
        defaultSubcommand: StatusCommand.self
    )
}
