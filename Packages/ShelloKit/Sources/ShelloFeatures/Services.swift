import ShelloStorage
import SwiftUI

extension EnvironmentValues {
    /// The hosts, groups and tags. The composition root opens the database once and passes its
    /// repository here; without it, the screens say that the hosts are unavailable.
    @Entry public var hostRepository: HostRepository? = nil
}
