import CryptoKit
import Foundation
import Security

/// The transport's only certificate rule: the SHA-256 of the leaf certificate's DER must equal the saved pin.
/// Nothing is evaluated (no chain, hostname or expiry check), because the host's certificate is self-signed
/// without a SAN; its identity is exactly the fingerprint the user approved.
enum ServerTrustPolicy {
    enum Verdict: Equatable {
        case matchesPin(CertificateFingerprint)
        /// First use (no pin) or a changed certificate.
        case needsApproval(CertificateFingerprint)
        case noCertificate
    }

    static func fingerprint(ofCertificateDER der: Data) -> CertificateFingerprint {
        CertificateFingerprint(digest: SHA256.hash(data: der))
    }

    static func verdict(leafCertificateDER der: Data?, pin: CertificateFingerprint?) -> Verdict {
        guard let der, !der.isEmpty else { return .noCertificate }
        let presented = fingerprint(ofCertificateDER: der)
        return presented == pin ? .matchesPin(presented) : .needsApproval(presented)
    }

    /// DER of the first (leaf) certificate the host presented.
    static func leafCertificateDER(of trust: SecTrust) -> Data? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else { return nil }
        return SecCertificateCopyData(leaf) as Data
    }
}
