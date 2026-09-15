import Foundation
import PotassiumProviderCore
import Testing

struct ShareLinkSettingsVerificationTests {
    enum Field: CaseIterable {
        case access, expiration, downloads, comments, editing, accessRequests, information, statistics
    }

    @Test(arguments: Field.allCases)
    func acknowledgedButUnappliedSettingIsRejected(_ field: Field) {
        let requested = KDriveShareLinkConfiguration(access: .inherit,
            validUntil: Date(timeIntervalSince1970: 1_700_000_000), allowsComments: true)
        var returned = requested
        switch field {
        case .access: returned.access = .public
        case .expiration: returned.validUntil = nil
        case .downloads: returned.allowsDownload.toggle()
        case .comments: returned.allowsComments.toggle()
        case .editing: returned.allowsEditing.toggle()
        case .accessRequests: returned.allowsAccessRequests.toggle()
        case .information: returned.showsFileInformation.toggle()
        case .statistics: returned.showsStatistics.toggle()
        }
        #expect(!requested.hasSameReportedSettings(as: returned))
    }

    @Test func unreportedPasswordAndSubsecondExpirationDoNotProduceFalseRejection() {
        let requested = KDriveShareLinkConfiguration(access: .password, password: "synthetic-only",
            validUntil: Date(timeIntervalSince1970: 1_700_000_000.75))
        var returned = requested
        returned.password = nil
        returned.validUntil = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(requested.hasSameReportedSettings(as: returned))
        returned.validUntil = returned.validUntil?.addingTimeInterval(1)
        #expect(!requested.hasSameReportedSettings(as: returned))
    }

    @Test func unchangedAbsentExpirationAndSuccessfulDownloadRestrictionMatch() {
        let requested = KDriveShareLinkConfiguration(access: .inherit, allowsDownload: false)
        #expect(requested.hasSameReportedSettings(as: requested))
    }
}
