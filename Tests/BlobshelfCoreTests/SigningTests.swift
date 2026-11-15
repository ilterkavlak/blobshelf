import Foundation
import Testing
@testable import BlobshelfCore

@Suite struct SigningTests {
    // The GET Object example from the AWS SigV4 documentation for S3 header authentication.
    @Test func matchesAWSDocumentedExample() {
        var request = URLRequest(url: URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!)
        request.setValue("bytes=0-9", forHTTPHeaderField: "Range")
        let creds = SigningCredentials(accessKeyId: "AKIAIOSFODNN7EXAMPLE",
                                       secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
                                       sessionToken: nil, region: "us-east-1")
        SigV4.sign(&request, with: creds, payloadHash: SigV4.emptyPayloadHash,
                   date: Date(timeIntervalSince1970: 1_369_353_600))
        #expect(request.value(forHTTPHeaderField: "Authorization") ==
            "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request,SignedHeaders=host;range;x-amz-content-sha256;x-amz-date,Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
    }

    @Test func signsSessionToken() {
        var request = URLRequest(url: URL(string: "https://acct.r2.cloudflarestorage.com/b/k")!)
        let creds = SigningCredentials(accessKeyId: "id", secretAccessKey: "secret", sessionToken: "tok", region: "auto")
        SigV4.sign(&request, with: creds, payloadHash: SigV4.unsignedPayload)
        #expect(request.value(forHTTPHeaderField: "x-amz-security-token") == "tok")
        #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("SignedHeaders=host;x-amz-content-sha256;x-amz-date;x-amz-security-token") == true)
    }

    @Test func encodesKeys() {
        #expect(KeyEncoding.encode("a b/c+d.txt", keepSlash: true) == "a%20b/c%2Bd.txt")
        #expect(KeyEncoding.encode("a/b") == "a%2Fb")
        #expect(KeyEncoding.encode("ü~_-.") == "%C3%BC~_-.")
        #expect(KeyEncoding.query([("prefix", "a b/"), ("list-type", "2")]) == "prefix=a%20b%2F&list-type=2")
    }
}
