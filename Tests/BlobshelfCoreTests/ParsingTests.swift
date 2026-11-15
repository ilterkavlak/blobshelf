import Foundation
import Testing
@testable import BlobshelfCore

@Suite struct ParsingTests {
    @Test func listPage() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
          <Name>b</Name><Prefix>docs/</Prefix><IsTruncated>true</IsTruncated>
          <NextContinuationToken>abc==</NextContinuationToken>
          <Contents><Key>docs/a &amp; b.txt</Key><Size>12</Size><LastModified>2024-01-02T03:04:05.000Z</LastModified></Contents>
          <Contents><Key>docs/c.bin</Key><Size>0</Size><LastModified>2024-01-02T03:04:05Z</LastModified></Contents>
          <CommonPrefixes><Prefix>docs/sub/</Prefix></CommonPrefixes>
        </ListBucketResult>
        """
        let page = try #require(S3XML.listPage(Data(xml.utf8)))
        #expect(page.objects.map(\.key) == ["docs/a & b.txt", "docs/c.bin"])
        #expect(page.objects[0].size == 12)
        #expect(page.objects[0].lastModified == Date(timeIntervalSince1970: 1_704_164_645))
        #expect(page.objects[1].lastModified != nil)
        #expect(page.commonPrefixes == ["docs/sub/"])
        #expect(page.nextContinuationToken == "abc==")
    }

    @Test func untruncatedListHasNoToken() throws {
        let xml = "<ListBucketResult><IsTruncated>false</IsTruncated><NextContinuationToken>x</NextContinuationToken></ListBucketResult>"
        #expect(try #require(S3XML.listPage(Data(xml.utf8))).nextContinuationToken == nil)
    }

    @Test func errorBody() {
        let xml = "<Error><Code>NoSuchKey</Code><Message>The specified key does not exist.</Message></Error>"
        #expect(S3XML.error(Data(xml.utf8), status: 404) == S3Error(status: 404, code: "NoSuchKey", message: "The specified key does not exist."))
        #expect(S3XML.error(Data(), status: 500).code == "HTTP500")
        #expect(S3XML.embeddedError(Data("<CopyObjectResult/>".utf8), status: 200) == nil)
    }

    @Test func multipartAndDelete() {
        #expect(S3XML.uploadID(Data("<InitiateMultipartUploadResult><UploadId>u1</UploadId></InitiateMultipartUploadResult>".utf8)) == "u1")
        let errors = S3XML.deleteErrors(Data("<DeleteResult><Error><Key>k</Key><Code>AccessDenied</Code><Message>no</Message></Error></DeleteResult>".utf8))
        #expect(errors.map(\.key) == ["k"])
        #expect(S3XML.escape("a<&>'\"") == "a&lt;&amp;&gt;&apos;&quot;")
    }

    @Test func token() throws {
        func make(_ version: UInt8, _ bucket: String, _ pw: String, _ hash: String, extra: [UInt8] = []) -> String {
            let p = [UInt8](pw.utf8)
            var b: [UInt8] = [version, 0, UInt8(bucket.utf8.count), UInt8(p.count >> 8), UInt8(p.count & 0xff), UInt8(hash.utf8.count)]
            b += Array(bucket.utf8) + p + Array(hash.utf8) + extra
            return Data(b).base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let token = try #require(BlobToken(make(2, "bkt_123", String(repeating: "p", count: 300), "h4sh")))
        #expect(token == BlobToken(" " + make(2, "bkt_123", String(repeating: "p", count: 300), "h4sh") + "\n"))
        #expect(token.bucketID == "bkt_123")
        #expect(token.hashForDomain == "h4sh")
        #expect(BlobToken(make(1, "b", "p", "h")) == nil)
        #expect(BlobToken(make(2, "b", "p", "h", extra: [0])) == nil)
        #expect(BlobToken("not a token!") == nil)
    }

    @Test func credentialsDecode() throws {
        let json = """
        {"accessKeyId":"a","secretAccessKey":"s","sessionToken":"t","endpoint":"https://x.r2.cloudflarestorage.com",
         "bucket":"b","region":"auto","expiresAt":1700000000,"visibility":"public","permission":"object-read-only","readOnlyReason":"quota"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let c = try decoder.decode(BlobCredentials.self, from: Data(json.utf8))
        #expect(c.isReadOnly && c.isPublic && c.readOnlyReason == "quota")
        #expect(c.expiresAt == Date(timeIntervalSince1970: 1_700_000_000))
    }
}
