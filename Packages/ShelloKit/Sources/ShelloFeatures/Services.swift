import ShelloStorage
import SwiftUI

extension EnvironmentValues {
    /// The hosts, groups and tags. The composition root opens the database once and passes its
    /// repository here; without it, the screens say that the hosts are unavailable.
    @Entry public var hostRepository: HostRepository? = nil

    /// Export and import of all non-secret data, on the same database as `hostRepository`.
    /// Without it, Settings leaves export and import out.
    @Entry public var exportRepository: ExportRepository? = nil
}
