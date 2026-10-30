import Testing
@testable import SSHCompanion

struct SSHConfigParserTests {
    @Test func parsesHostBlocks() {
        let config = """
        # comentário
        Host *
            ServerAliveInterval 60

        Host web prod-web
            HostName 203.0.113.10
            User deploy
            Port 2222
            IdentityFile ~/.ssh/deploy
            IdentityFile ~/.ssh/other

        Host db
          HostName=db.internal

        Match host db
            User admin
        """
        let hosts = SSHConfigParser.parse(contents: config)
        #expect(hosts.map(\.alias) == ["web", "prod-web", "db"])
        #expect(hosts[0].hostName == "203.0.113.10")
        #expect(hosts[0].user == "deploy")
        #expect(hosts[0].port == 2222)
        #expect(hosts[0].identityFile == "~/.ssh/deploy")
        #expect(hosts[2].hostName == "db.internal")
        #expect(hosts[2].user == nil)
        #expect(hosts[2].port == 22)
    }
}
