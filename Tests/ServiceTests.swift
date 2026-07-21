import XCTest
@testable import SwiftMinerCore

@MainActor
final class ServiceTests: XCTestCase {
    
    var mockSession: URLSession!
    var authService: TwitchAuthService!
    var apiClient: TwitchAPIClient!
    
    override func setUp() {
        super.setUp()
        
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        mockSession = URLSession(configuration: config)
        
        authService = TwitchAuthService(clientId: "test_client", tokenStore: TestTokenStore())
        apiClient = TwitchAPIClient(authService: authService, clientId: "test_client", session: mockSession)
    }
    
    override func tearDown() {
        MockURLProtocol.stubResponseData = nil
        MockURLProtocol.stubError = nil
        MockURLProtocol.lastRequest = nil
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }
    
    // MARK: - TwitchAPIClient Tests
    
    func testGetCurrentUser() async throws {
        let jsonString = """
        {
            "data": [
                {
                    "id": "12345",
                    "login": "testuser",
                    "display_name": "TestUser",
                    "type": "",
                    "broadcaster_type": "",
                    "description": "Test bio",
                    "profile_image_url": "https://example.com/img.png",
                    "offline_image_url": "https://example.com/offline.png",
                    "view_count": 100,
                    "created_at": "2020-01-01T00:00:00Z"
                }
            ]
        }
        """
        MockURLProtocol.stubResponseData = jsonString.data(using: .utf8)
        
        let user = try await apiClient.getCurrentUser()
        
        XCTAssertEqual(user.id, "12345")
        XCTAssertEqual(user.login, "testuser")
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.path, "/helix/users")
    }

    func testGetChannelByLoginResolvesNumericId() async throws {
        let jsonString = """
        {
            "data": [
                {
                    "id": "98765",
                    "login": "dropstreamer",
                    "display_name": "DropStreamer",
                    "type": "",
                    "broadcaster_type": "",
                    "description": "",
                    "profile_image_url": "https://example.com/img.png",
                    "offline_image_url": "",
                    "view_count": 100,
                    "created_at": "2020-01-01T00:00:00Z"
                }
            ]
        }
        """
        MockURLProtocol.stubResponseData = jsonString.data(using: .utf8)

        let channel = try await apiClient.getChannel(login: "DropStreamer")

        XCTAssertEqual(channel.id, "98765")
        XCTAssertEqual(channel.login, "dropstreamer")
        XCTAssertEqual(channel.displayName, "DropStreamer")
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.path, "/helix/users")
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.query, "login=dropstreamer")
    }
    
    func testGetGameSlug() async throws {
        let jsonString = """
        {
            "data": {
                "game": {
                    "name": "fortnite"
                }
            }
        }
        """
        MockURLProtocol.stubResponseData = jsonString.data(using: .utf8)
        
        let slug = try await apiClient.getGameSlug(name: "Fortnite")
        
        XCTAssertEqual(slug, "fortnite")
        
        let lastRequest = MockURLProtocol.lastRequest
        XCTAssertNotNil(lastRequest)
        
        let bodyData = lastRequest?.httpBody
        XCTAssertNotNil(bodyData)
        
        if let bodyData = bodyData,
           let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
           let variables = json["variables"] as? [String: Any] {
            XCTAssertEqual(variables["name"] as? String, "Fortnite")
        }
    }

    func testFindLiveChannelsUsesCanonicalCategorySearchWhenDropsNameDiffersFromDirectoryName() async throws {
        let redirectNames = StringRequestRecorder()
        let directorySlugs = StringRequestRecorder()
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!

            if request.url?.path == "/integrity" {
                return (response, #"{"token":"integrity-token","expiration":4102444800000}"#.data(using: .utf8)!)
            }

            if request.url?.path == "/helix/search/categories" {
                let payload = """
                {
                  "data": [
                    {
                      "id": "460630",
                      "name": "Tom Clancy's Rainbow Six Siege",
                      "box_art_url": "https://example.com/{width}x{height}.jpg"
                    }
                  ]
                }
                """
                return (response, payload.data(using: .utf8)!)
            }

            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
            let operationName = body?["operationName"] as? String
            let variables = body?["variables"] as? [String: Any]

            switch operationName {
            case "DirectoryGameRedirect":
                let requestedName = variables?["name"] as? String ?? ""
                redirectNames.append(requestedName)
                let payload: String
                if requestedName == "Tom Clancy's Rainbow Six Siege" {
                    payload = #"{"data":{"game":{"name":"tom-clancys-rainbow-six-siege"}}}"#
                } else {
                    payload = #"{"data":{"game":{"name":"rainbow-six-siege"}}}"#
                }
                return (response, payload.data(using: .utf8)!)

            case "DirectoryPage_Game":
                let slug = variables?["slug"] as? String ?? ""
                directorySlugs.append(slug)
                let gameId = slug == "tom-clancys-rainbow-six-siege" ? "460630" : "wrong-game"
                let payload = """
                {
                  "data": {
                    "game": {
                      "id": "\(gameId)",
                      "displayName": "Tom Clancy's Rainbow Six Siege",
                      "streams": {
                        "edges": [
                          {
                            "node": {
                              "viewersCount": 1234,
                              "game": {
                                "id": "\(gameId)",
                                "displayName": "Tom Clancy's Rainbow Six Siege"
                              },
                              "broadcaster": {
                                "id": "channel-1",
                                "login": "r6streamer",
                                "displayName": "R6Streamer"
                              }
                            }
                          }
                        ]
                      }
                    }
                  }
                }
                """
                return (response, payload.data(using: .utf8)!)

            default:
                return (response, #"{"data":{}}"#.data(using: .utf8)!)
            }
        }

        let dropsService = DropsService(apiClient: apiClient)
        let channels = try await dropsService.findLiveChannels(
            forGame: Game(id: "460630", name: "Rainbow Six Siege")
        )

        XCTAssertEqual(channels.map(\.login), ["r6streamer"])
        XCTAssertEqual(redirectNames.recordedValues, ["Rainbow Six Siege", "Tom Clancy's Rainbow Six Siege"])
        XCTAssertEqual(directorySlugs.recordedValues, ["rainbow-six-siege", "tom-clancys-rainbow-six-siege"])
    }

    func testFetchDropCampaignsKeepsConnectionStateFromDetails() async throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let startAt = formatter.string(from: Date().addingTimeInterval(-3600))
        let endAt = formatter.string(from: Date().addingTimeInterval(3600))
        let boxArtURL = "https://example.com/the-finals-box.png"

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!

            if request.url?.path == "/integrity" {
                return (response, #"{"token":"integrity-token","expiration":4102444800000}"#.data(using: .utf8)!)
            }

            let bodyData = request.httpBody ?? Data()
            let body = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any]
            let operationName = body?["operationName"] as? String

            switch operationName {
            case "ViewerDropsDashboard":
                let json = """
                {
                  "data": {
                    "currentUser": {
                      "dropCampaigns": [
                        {
                          "id": "finals-respec",
                          "name": "RESPEC ORDER DROPS",
                          "status": "ACTIVE",
                          "startAt": "\(startAt)",
                          "endAt": "\(endAt)",
                          "self": { "isAccountConnected": false },
                          "game": {
                            "id": "1910103699",
                            "displayName": "THE FINALS",
                            "boxArtURL": "\(boxArtURL)"
                          }
                        }
                      ]
                    }
                  }
                }
                """
                return (response, json.data(using: .utf8)!)

            case "DropCampaignDetails":
                let json = """
                {
                  "data": {
                    "user": {
                      "dropCampaign": {
                        "id": "finals-respec",
                        "name": "RESPEC ORDER DROPS",
                        "status": "ACTIVE",
                        "startAt": "\(startAt)",
                        "endAt": "\(endAt)",
                        "self": { "isAccountConnected": true },
                        "allow": { "isEnabled": false, "channels": null },
                        "game": {
                          "id": "1910103699",
                          "displayName": "THE FINALS"
                        },
                        "timeBasedDrops": [
                          {
                            "id": "tangerine-spear",
                            "name": "Tangerine Spear",
                            "requiredMinutesWatched": 60,
                            "benefitEdges": [
                              {
                                "benefit": {
                                  "id": "benefit-spear",
                                  "name": "Tangerine Spear",
                                  "imageAssetURL": "https://example.com/spear.png",
                                  "distributionType": "DIRECT_ENTITLEMENT"
                                }
                              }
                            ],
                            "self": {
                              "currentMinutesWatched": 0,
                              "isClaimed": false,
                              "dropInstanceID": "instance-spear"
                            }
                          }
                        ]
                      }
                    }
                  }
                }
                """
                return (response, json.data(using: .utf8)!)

            default:
                return (response, #"{"data":{}}"#.data(using: .utf8)!)
            }
        }

        await apiClient.setUserLogin("ruffcrumble")
        let campaigns = try await apiClient.fetchDropCampaigns()

        XCTAssertEqual(campaigns.count, 1)
        let campaign = try XCTUnwrap(campaigns.first)
        XCTAssertEqual(campaign.name, "RESPEC ORDER DROPS")
        XCTAssertEqual(campaign.game.name, "THE FINALS")
        XCTAssertEqual(campaign.game.boxArtURL?.absoluteString, boxArtURL)
        XCTAssertTrue(campaign.isAccountConnected)
        XCTAssertFalse(campaign.allowIsEnabled ?? true)
        XCTAssertTrue(campaign.hasDropsEnabled)
        XCTAssertTrue(campaign.channels.isEmpty)
        XCTAssertEqual(campaign.drops.map(\.name), ["Tangerine Spear"])
        XCTAssertTrue(campaign.isMiningEligible)
    }

    func testFetchDropCampaignsParsesNameOnlyApprovedChannel() async throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let startAt = formatter.string(from: Date().addingTimeInterval(-3600))
        let endAt = formatter.string(from: Date().addingTimeInterval(3600))
        let campaignId = "cdl-day-4-\(UUID().uuidString)"

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!

            if request.url?.path == "/integrity" {
                return (response, #"{"token":"integrity-token","expiration":4102444800000}"#.data(using: .utf8)!)
            }

            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
            switch body?["operationName"] as? String {
            case "ViewerDropsDashboard":
                let json = """
                {
                  "data": {
                    "currentUser": {
                      "dropCampaigns": [
                        {
                          "id": "\(campaignId)",
                          "name": "CDL Championship - Day 4",
                          "status": "ACTIVE",
                          "startAt": "\(startAt)",
                          "endAt": "\(endAt)",
                          "self": { "isAccountConnected": true },
                          "game": {
                            "id": "2012789438",
                            "displayName": "Call of Duty: Black Ops 7"
                          }
                        }
                      ]
                    }
                  }
                }
                """
                return (response, json.data(using: .utf8)!)

            case "DropCampaignDetails":
                let json = """
                {
                  "data": {
                    "user": {
                      "dropCampaign": {
                        "id": "\(campaignId)",
                        "name": "CDL Championship - Day 4",
                        "status": "ACTIVE",
                        "startAt": "\(startAt)",
                        "endAt": "\(endAt)",
                        "self": { "isAccountConnected": true },
                        "allow": {
                          "isEnabled": true,
                          "channels": [
                            { "id": "1494318985", "name": "CallofDuty_Esports" }
                          ]
                        },
                        "game": {
                          "id": "2012789438",
                          "displayName": "Call of Duty: Black Ops 7"
                        },
                        "timeBasedDrops": [
                          {
                            "id": "cdl-drop",
                            "name": "30 Minute Drop",
                            "requiredMinutesWatched": 30,
                            "benefitEdges": [],
                            "self": {
                              "currentMinutesWatched": 0,
                              "isClaimed": false,
                              "dropInstanceID": "cdl-instance"
                            }
                          }
                        ]
                      }
                    }
                  }
                }
                """
                return (response, json.data(using: .utf8)!)

            default:
                return (response, #"{"data":{}}"#.data(using: .utf8)!)
            }
        }

        await apiClient.setUserLogin("cdlviewer")
        let campaigns = try await apiClient.fetchDropCampaigns()
        let campaign = try XCTUnwrap(campaigns.first)

        XCTAssertEqual(campaign.channels.count, 1)
        XCTAssertEqual(campaign.channels.first?.id, "1494318985")
        XCTAssertEqual(campaign.channels.first?.login, "CallofDuty_Esports")
        XCTAssertEqual(campaign.channels.first?.displayName, "CallofDuty_Esports")
        XCTAssertTrue(campaign.channels.first?.aclBased ?? false)
        XCTAssertTrue(campaign.hasKnownChannelRestrictions)
        XCTAssertFalse(campaign.hasUnresolvedChannelRestrictions)
    }

    func testCampaignServiceInventoryFillsMissingApprovedChannels() {
        let now = Date()
        let game = Game(id: "2012789438", name: "Call of Duty: Black Ops 7")
        let dashboard = Campaign(
            id: "cdl-day-4",
            name: "CDL Championship - Day 4",
            game: game,
            status: .active,
            startDate: now.addingTimeInterval(-3600),
            endDate: now.addingTimeInterval(3600),
            drops: [Drop(id: "drop", name: "30 Minute Drop", requiredMinutes: 30)],
            channels: [],
            isAccountConnected: false,
            allowIsEnabled: true
        )
        let inventory = Campaign(
            id: dashboard.id,
            name: dashboard.name,
            game: game,
            status: .active,
            startDate: dashboard.startDate,
            endDate: dashboard.endDate,
            drops: dashboard.drops,
            channels: [
                Channel(
                    id: "1494318985",
                    login: "CallofDuty_Esports",
                    displayName: "CallofDuty_Esports",
                    aclBased: true
                )
            ],
            isAccountConnected: true,
            allowIsEnabled: true
        )

        let merged = CampaignService.mergeDashboardCampaign(dashboard, withInventory: inventory)

        XCTAssertEqual(merged.channels.map(\.login), ["CallofDuty_Esports"])
        XCTAssertTrue(merged.isAccountConnected)
        XCTAssertTrue(merged.hasKnownChannelRestrictions)
    }

    func testFetchDropCampaignsReusesRecentCampaignDetails() async throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let startAt = formatter.string(from: Date().addingTimeInterval(-3600))
        let endAt = formatter.string(from: Date().addingTimeInterval(3600))
        let operations = StringRequestRecorder()

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!

            if request.url?.path == "/integrity" {
                return (response, #"{"token":"integrity-token","expiration":4102444800000}"#.data(using: .utf8)!)
            }

            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
            let operationName = body?["operationName"] as? String ?? ""
            operations.append(operationName)

            switch operationName {
            case "ViewerDropsDashboard":
                let json = """
                {
                  "data": {
                    "currentUser": {
                      "dropCampaigns": [
                        {
                          "id": "cached-campaign",
                          "name": "Cached Campaign",
                          "status": "ACTIVE",
                          "startAt": "\(startAt)",
                          "endAt": "\(endAt)",
                          "self": { "isAccountConnected": true },
                          "game": {
                            "id": "game-1",
                            "displayName": "Cache Game"
                          }
                        }
                      ]
                    }
                  }
                }
                """
                return (response, json.data(using: .utf8)!)

            case "DropCampaignDetails":
                let json = """
                {
                  "data": {
                    "user": {
                      "dropCampaign": {
                        "id": "cached-campaign",
                        "name": "Cached Campaign",
                        "status": "ACTIVE",
                        "startAt": "\(startAt)",
                        "endAt": "\(endAt)",
                        "self": { "isAccountConnected": true },
                        "allow": { "isEnabled": false, "channels": null },
                        "game": {
                          "id": "game-1",
                          "displayName": "Cache Game"
                        },
                        "timeBasedDrops": [
                          {
                            "id": "drop-1",
                            "name": "Drop One",
                            "requiredMinutesWatched": 30,
                            "benefitEdges": [
                              {
                                "benefit": {
                                  "id": "benefit-1",
                                  "name": "Drop One",
                                  "distributionType": "DIRECT_ENTITLEMENT"
                                }
                              }
                            ],
                            "self": {
                              "currentMinutesWatched": 0,
                              "isClaimed": false,
                              "dropInstanceID": "instance-1"
                            }
                          }
                        ]
                      }
                    }
                  }
                }
                """
                return (response, json.data(using: .utf8)!)

            default:
                return (response, #"{"data":{}}"#.data(using: .utf8)!)
            }
        }

        await apiClient.setUserLogin("cacheuser")

        let first = try await apiClient.fetchDropCampaigns()
        let second = try await apiClient.fetchDropCampaigns()

        XCTAssertEqual(first.map(\.id), ["cached-campaign"])
        XCTAssertEqual(second.map(\.id), ["cached-campaign"])
        XCTAssertEqual(operations.recordedValues.filter { $0 == "ViewerDropsDashboard" }.count, 2)
        XCTAssertEqual(operations.recordedValues.filter { $0 == "DropCampaignDetails" }.count, 1)
    }

    func testFetchDropCampaignsReusesSharedCampaignMetadataAcrossClients() async throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let startAt = formatter.string(from: Date().addingTimeInterval(-3600))
        let endAt = formatter.string(from: Date().addingTimeInterval(3600))
        let campaignId = "shared-campaign-\(UUID().uuidString)"
        let operations = StringRequestRecorder()

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!

            if request.url?.path == "/integrity" {
                return (response, #"{"token":"integrity-token","expiration":4102444800000}"#.data(using: .utf8)!)
            }

            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
            let operationName = body?["operationName"] as? String ?? ""
            operations.append(operationName)

            switch operationName {
            case "ViewerDropsDashboard":
                let json = """
                {
                  "data": {
                    "currentUser": {
                      "dropCampaigns": [
                        {
                          "id": "\(campaignId)",
                          "name": "Shared Campaign",
                          "status": "ACTIVE",
                          "startAt": "\(startAt)",
                          "endAt": "\(endAt)",
                          "self": { "isAccountConnected": true },
                          "game": {
                            "id": "shared-game",
                            "displayName": "Shared Game"
                          }
                        }
                      ]
                    }
                  }
                }
                """
                return (response, json.data(using: .utf8)!)

            case "DropCampaignDetails":
                let json = """
                {
                  "data": {
                    "user": {
                      "dropCampaign": {
                        "id": "\(campaignId)",
                        "name": "Shared Campaign",
                        "status": "ACTIVE",
                        "startAt": "\(startAt)",
                        "endAt": "\(endAt)",
                        "self": { "isAccountConnected": true },
                        "allow": { "isEnabled": false, "channels": null },
                        "game": {
                          "id": "shared-game",
                          "displayName": "Shared Game"
                        },
                        "timeBasedDrops": [
                          {
                            "id": "shared-drop",
                            "name": "Shared Drop",
                            "requiredMinutesWatched": 30,
                            "benefitEdges": [
                              {
                                "benefit": {
                                  "id": "shared-benefit",
                                  "name": "Shared Drop",
                                  "distributionType": "DIRECT_ENTITLEMENT"
                                }
                              }
                            ],
                            "self": {
                              "currentMinutesWatched": 12,
                              "isClaimed": false,
                              "dropInstanceID": "shared-instance"
                            }
                          }
                        ]
                      }
                    }
                  }
                }
                """
                return (response, json.data(using: .utf8)!)

            case "DropsPage_ClaimDropRewards":
                let json = """
                {
                  "data": {
                    "claimDropBenefit": {
                      "id": "shared-instance",
                      "status": "CLAIMED"
                    }
                  }
                }
                """
                return (response, json.data(using: .utf8)!)

            default:
                return (response, #"{"data":{}}"#.data(using: .utf8)!)
            }
        }

        await apiClient.setUserLogin("firstuser")
        let secondClient = TwitchAPIClient(
            authService: authService,
            clientId: "test_client",
            session: mockSession
        )
        await secondClient.setUserLogin("seconduser")
        let thirdClient = TwitchAPIClient(
            authService: authService,
            clientId: "test_client",
            session: mockSession
        )
        await thirdClient.setUserLogin("thirduser")

        let first = try await apiClient.fetchDropCampaigns()
        let second = try await secondClient.fetchDropCampaigns()

        XCTAssertEqual(first.first?.drops.first?.progress?.currentMinutes, 12)
        XCTAssertNil(second.first?.drops.first?.progress)
        XCTAssertEqual(second.first?.isAccountConnected, true)
        XCTAssertEqual(operations.recordedValues.filter { $0 == "ViewerDropsDashboard" }.count, 2)
        XCTAssertEqual(operations.recordedValues.filter { $0 == "DropCampaignDetails" }.count, 1)

        let claim = try await apiClient.claimDrop(dropInstanceId: "shared-instance")
        XCTAssertEqual(claim.status, "CLAIMED")

        _ = try await thirdClient.fetchDropCampaigns()
        XCTAssertEqual(operations.recordedValues.filter { $0 == "ViewerDropsDashboard" }.count, 3)
        XCTAssertEqual(operations.recordedValues.filter { $0 == "DropCampaignDetails" }.count, 2)
    }

    func testFetchAvailableDropsUsesShortLivedChannelCache() async throws {
        let operations = StringRequestRecorder()

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!

            if request.url?.path == "/integrity" {
                return (response, #"{"token":"integrity-token","expiration":4102444800000}"#.data(using: .utf8)!)
            }

            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
            let operationName = body?["operationName"] as? String ?? ""
            operations.append(operationName)

            let json = """
            {
              "data": {
                "channel": {
                  "viewerDropCampaigns": [
                    { "id": "campaign-a" },
                    { "id": "campaign-b" }
                  ]
                }
              }
            }
            """
            return (response, json.data(using: .utf8)!)
        }

        let first = try await apiClient.fetchAvailableDrops(channelId: "channel-1")
        let second = try await apiClient.fetchAvailableDrops(channelId: "channel-1")

        XCTAssertEqual(first, ["campaign-a", "campaign-b"])
        XCTAssertEqual(second, ["campaign-a", "campaign-b"])
        XCTAssertEqual(operations.recordedValues.filter { $0 == "DropsHighlightService_AvailableDrops" }.count, 1)
    }

    func testGetLiveChannelsUsesShortLivedDirectoryCache() async throws {
        let operations = StringRequestRecorder()

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!

            if request.url?.path == "/integrity" {
                return (response, #"{"token":"integrity-token","expiration":4102444800000}"#.data(using: .utf8)!)
            }

            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
            let operationName = body?["operationName"] as? String ?? ""
            operations.append(operationName)

            let json = """
            {
              "data": {
                "game": {
                  "id": "game-1",
                  "displayName": "Cache Game",
                  "streams": {
                    "edges": [
                      {
                        "node": {
                          "viewersCount": 123,
                          "game": {
                            "id": "game-1",
                            "displayName": "Cache Game"
                          },
                          "broadcaster": {
                            "id": "channel-1",
                            "login": "cachedstreamer",
                            "displayName": "CachedStreamer"
                          }
                        }
                      }
                    ]
                  }
                }
              }
            }
            """
            return (response, json.data(using: .utf8)!)
        }

        let first = try await apiClient.getLiveChannels(gameSlug: "cache-game", expectedGameId: "game-1")
        let second = try await apiClient.getLiveChannels(gameSlug: "cache-game", expectedGameId: "game-1")

        XCTAssertEqual(first.map(\.login), ["cachedstreamer"])
        XCTAssertEqual(second.map(\.login), ["cachedstreamer"])
        XCTAssertEqual(operations.recordedValues.filter { $0 == "DirectoryPage_Game" }.count, 1)
    }

    func testJustChattingDoesNotSupportSteamArtwork() {
        XCTAssertFalse(SteamArtworkService.supportsSteamArtwork(forGameName: "Just Chatting"))
        XCTAssertFalse(SteamArtworkService.supportsSteamArtwork(forGameName: " just chatting "))
        XCTAssertFalse(SteamArtworkService.supportsSteamArtwork(forGameName: "Anything", gameId: "509658"))
        XCTAssertTrue(SteamArtworkService.supportsSteamArtwork(forGameName: "THE FINALS", gameId: "1910103699"))
    }
    
    // MARK: - CommunityPointsService Tests
    
    func testCommunityPointsAutoClaim() async throws {
        let pointsService = CommunityPointsService(apiClient: apiClient)
        
        // Mock GQL response for context
        let contextJson = """
        {
            "data": {
                "community": {
                    "channel": {
                        "communityPoints": {
                            "balance": 500,
                            "user": {
                                "self": {
                                    "communityPointsAvailableClaim": {
                                        "id": "claim_123"
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        """
        MockURLProtocol.stubResponseData = contextJson.data(using: .utf8)
        
        // Start auto-claim
        await pointsService.startAutoClaim(channelLogin: "testchannel", channelId: "999")
        
        // Wait a bit for the first poll
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1s
        
        // Verify a request was made
        XCTAssertNotNil(MockURLProtocol.lastRequest)
        
        await pointsService.stopAutoClaim()
    }
}

// MARK: - Mocking Infrastructure

private final class StringRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ value: String) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var recordedValues: [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var stubResponseData: Data?
    nonisolated(unsafe) static var stubError: Error?
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    
    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }
    
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }
    
    override func startLoading() {
        var captured = request
        // URLSession moves POST body to httpBodyStream when routed through URLProtocol.
        // Drain the stream and re-attach it as httpBody so tests can inspect it.
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            let bufferSize = 4096
            var buffer = [UInt8](repeating: 0, count: bufferSize)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: bufferSize)
                if read > 0 { data.append(contentsOf: buffer[..<read]) }
            }
            stream.close()
            if !data.isEmpty { captured.httpBody = data }
        }
        MockURLProtocol.lastRequest = captured

        if let handler = MockURLProtocol.requestHandler {
            do {
                let (response, data) = try handler(captured)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
            return
        }
        
        if let error = MockURLProtocol.stubError {
            client?.urlProtocol(self, didFailWithError: error)
        } else {
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            
            if let data = MockURLProtocol.stubResponseData {
                client?.urlProtocol(self, didLoad: data)
            }
            
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    
    override func stopLoading() {}
}
