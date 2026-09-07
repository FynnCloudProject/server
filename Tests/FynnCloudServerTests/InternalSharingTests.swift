import XCTest
import Vapor
import Fluent
import FluentSQLiteDriver
@testable import FynnCloudServer

final class InternalSharingTests: XCTestCase {
    var app: Application!
    var ownerID: UUID!
    var collaboratorID: UUID!
    var groupUser1ID: UUID!
    var groupUser2ID: UUID!
    var testGroupID: Int!
    var files: FileServiceContext!

    override func setUp() async throws {
        app = try await Application.make(.testing)
        app.databases.use(.sqlite(.memory), as: .sqlite)

        app.migrations.add(CreateInitialMigration())
        app.migrations.add(AddDisplayNameToUsers())
        app.migrations.add(CreateSyncLog())
        app.migrations.add(CreateOAuthCode())
        app.migrations.add(AddClientIdAndStateToOAuthCode())
        app.migrations.add(CreateOAuthGrant())
        app.migrations.add(UpdateGrantForRotation())
        app.migrations.add(AddGracePeriodToOAuthGrant())
        app.migrations.add(AddLastUsedAtToOAuthGrant())
        app.migrations.add(AddIPAddressToOAuthGrant())
        app.migrations.add(CreateMultipartUploadSessions())
        app.migrations.add(CreateGroups())
        app.migrations.add(CreateAppSettings())
        app.migrations.add(UpdateUnlimitedTier())
        app.migrations.add(AddIsAdminToGroups())
        app.migrations.add(AddAvatarUpdatedAtToUsers())
        app.migrations.add(LowercaseUsernames())
        app.migrations.add(AddIndicesToFileMetadata())
        app.migrations.add(AddTrashGroupToFileMetadata())
        app.migrations.add(RewriteSyncInfrastructure())
        app.migrations.add(CreateShareLinks())
        app.migrations.add(CreateFilenameSearchIndex())
        app.migrations.add(AddContentHashToFileMetadata())
        app.migrations.add(CreateFileEmbeddings())
        app.migrations.add(UpdateEmbeddingDimension())
        app.migrations.add(AddHasThumbnailToFileMetadata())
        app.migrations.add(CreateSubscriptions())
        app.migrations.add(AddLinkTypeAndRequiresAuthToShareLink())
        app.migrations.add(AddAncestorIDsToFileMetadata())
        app.migrations.add(AddAllUsersGroup())
        app.migrations.add(RenameEuroOfficeUrlSetting())
        app.migrations.add(CreateUserIdentities())
        app.migrations.add(AddSSOManagedToGroups())
        app.migrations.add(AddSourceToUserGroups())
        app.migrations.add(CreateUserTOTP())
        app.migrations.add(CreateUserTOTPRecoveryCode())
        app.migrations.add(DropRecoveryCodesFromUserTOTP())
        app.migrations.add(AddSSOSourceToGroups())
        app.migrations.add(RenameSSOSourceToSourceOnGroups())
        app.migrations.add(AddUploadedAtToFileMetadata())
        app.migrations.add(OverhaulSyncInfrastructure())
        app.migrations.add(CreateInternalShares())
        app.migrations.add(DropOAuthCodes())
        app.migrations.add(CreateUserFavorites())
        app.migrations.add(DropMultipartUploadSessions())
        try await app.autoMigrate()
        app.config = try ServerConfig.load(for: app)

        let mockProvider = TestStorage.createLocalProvider()
        let storageService = StorageService(provider: mockProvider, eventLoop: app.eventLoopGroup.next())
        files = FileServiceContext(
            db: app.db, logger: app.logger,
            storage: storageService, redis: try await TestRedis.configure(app))

        let tier = StorageTier(name: "Test Tier", limitBytes: 100_000_000)
        try await tier.save(on: app.db)

        let owner = User(username: "owner", email: "owner@test.com", passwordHash: "h", displayName: "Alice Smith", tierID: try tier.requireID())
        try await owner.save(on: app.db)
        ownerID = try owner.requireID()

        let collaborator = User(username: "bob", email: "bob@test.com", passwordHash: "h", displayName: "Bob Jones", tierID: try tier.requireID())
        try await collaborator.save(on: app.db)
        collaboratorID = try collaborator.requireID()

        let gUser1 = User(username: "charlie", email: "charlie@test.com", passwordHash: "h", displayName: "Charlie Brown", tierID: try tier.requireID())
        try await gUser1.save(on: app.db)
        groupUser1ID = try gUser1.requireID()

        let gUser2 = User(username: "dave", email: "dave@test.com", passwordHash: "h", displayName: "Dave Wilson", tierID: try tier.requireID())
        try await gUser2.save(on: app.db)
        groupUser2ID = try gUser2.requireID()

        let group = Group(name: "Designers")
        try await group.save(on: app.db)
        testGroupID = try group.requireID()

        let ug1 = UserGroup(userID: groupUser1ID, groupID: testGroupID)
        try await ug1.save(on: app.db)
        let ug2 = UserGroup(userID: groupUser2ID, groupID: testGroupID)
        try await ug2.save(on: app.db)
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
    }

    func testDirectUserSharePermissions() async throws {
        let folder = try await files.files.createDirectory(name: "SharedFolder", parentID: nil as UUID?, userID: ownerID)
        let folderID = try folder.requireID()

        // Before sharing, bob should not have access
        do {
            _ = try await files.access.validateAccess(fileID: folderID, userID: collaboratorID, required: FilePermissions.read)
            XCTFail("Bob should not have access before share")
        } catch {}

        let share = InternalShare(fileID: folderID, granteeType: .user, granteeUserID: collaboratorID, role: .viewer, createdBy: ownerID)
        try await share.save(on: app.db)

        let access = try await files.access.validateAccess(fileID: folderID, userID: collaboratorID, required: FilePermissions.read)
        XCTAssertEqual(access.ownerID, ownerID)
        XCTAssertTrue(access.canRead)
        XCTAssertFalse(access.canWrite)
        XCTAssertFalse(access.canDelete)

        do {
            _ = try await files.access.validateAccess(fileID: folderID, userID: collaboratorID, required: FilePermissions.write)
            XCTFail("Viewer should not have write access")
        } catch {}

        share.role = .editor
        try await share.update(on: app.db)

        let editorAccess = try await files.access.validateAccess(fileID: folderID, userID: collaboratorID, required: FilePermissions.write)
        XCTAssertTrue(editorAccess.canRead)
        XCTAssertTrue(editorAccess.canWrite)
        XCTAssertTrue(editorAccess.canDelete)
        XCTAssertFalse(editorAccess.canShare)
    }

    func testGroupInheritanceAndHighestEffectiveRole() async throws {
        let folder = try await files.files.createDirectory(name: "TeamFolder", parentID: nil as UUID?, userID: ownerID)
        let folderID = try folder.requireID()

        // Share folder with group as Editor
        let groupShare = InternalShare(fileID: folderID, granteeType: .group, granteeGroupID: testGroupID, role: .editor, createdBy: ownerID)
        try await groupShare.save(on: app.db)

        // Also give Charlie a direct share as Viewer
        let directShare = InternalShare(fileID: folderID, granteeType: .user, granteeUserID: groupUser1ID, role: .viewer, createdBy: ownerID)
        try await directShare.save(on: app.db)

        // Charlie should get Editor (max(viewer, editor) == editor)
        let charlieAccess = try await files.access.validateAccess(fileID: folderID, userID: groupUser1ID, required: FilePermissions.write)
        XCTAssertTrue(charlieAccess.canWrite)
        XCTAssertTrue(charlieAccess.canRead)

        // Dave (group only) should also get Editor
        let daveAccess = try await files.access.validateAccess(fileID: folderID, userID: groupUser2ID, required: FilePermissions.write)
        XCTAssertTrue(daveAccess.canWrite)

        // Bob (not in group) should have no access
        do {
            _ = try await files.access.validateAccess(fileID: folderID, userID: collaboratorID, required: FilePermissions.read)
            XCTFail("Bob is not in group and should have no access")
        } catch {}
    }

    func testSubitemInheritanceViaAncestors() async throws {
        let parent = try await files.files.createDirectory(name: "Parent", parentID: nil as UUID?, userID: ownerID)
        let parentID = try parent.requireID()

        let child = try await files.files.createDirectory(name: "Child", parentID: parentID, userID: ownerID)
        let childID = try child.requireID()

        // Share Parent with Bob as Editor
        let share = InternalShare(fileID: parentID, granteeType: .user, granteeUserID: collaboratorID, role: .editor, createdBy: ownerID)
        try await share.save(on: app.db)

        // Bob should have write access on Child because child.ancestorIDs contains parentID
        let childAccess = try await files.access.validateAccess(fileID: childID, userID: collaboratorID, required: FilePermissions.write)
        XCTAssertTrue(childAccess.canWrite)
        XCTAssertTrue(childAccess.canRead)
        XCTAssertEqual(childAccess.ownerID, ownerID)
    }

    func testSharedListFilter() async throws {
        let folder = try await files.files.createDirectory(name: "ProjectAlpha", parentID: nil as UUID?, userID: ownerID)
        let folderID = try folder.requireID()

        let share = InternalShare(fileID: folderID, granteeType: .user, granteeUserID: collaboratorID, role: .viewer, createdBy: ownerID)
        try await share.save(on: app.db)

        let sharedIndex = try await files.listing.list(filter: FileListingService.FileFilter.shared, userID: collaboratorID)
        XCTAssertEqual(sharedIndex.files.count, 1)
        XCTAssertEqual(sharedIndex.files.first?.filename, "ProjectAlpha")
        XCTAssertEqual(sharedIndex.files.first?.permissions?.canWrite, false)
        XCTAssertEqual(sharedIndex.files.first?.permissions?.canRead, true)
    }

    func testSharedFileDownloadForGrantee() async throws {
        let created = try await files.files.createFile(name: "SharedDocument", type: .text, parentID: nil as UUID?, userID: ownerID)
        let fileID = try created.requireID()

        do {
            _ = try await files.files.getDownloadResponse(fileID: fileID, userID: collaboratorID)
            XCTFail("Collaborator should not be able to download unshared file")
        } catch {}

        let share = InternalShare(fileID: fileID, granteeType: .user, granteeUserID: collaboratorID, role: .viewer, createdBy: ownerID)
        try await share.save(on: app.db)

        let response = try await files.files.getDownloadResponse(fileID: fileID, userID: collaboratorID)
        XCTAssertEqual(response.status, .ok)

        do {
            _ = try await files.files.getDownloadResponse(fileID: fileID, userID: groupUser1ID)
            XCTFail("Non-grantee should not be able to download file")
        } catch {}
    }

    func testMultipartUploadInSharedFolder() async throws {
        let folder = try await files.files.createDirectory(name: "UploadFolder", parentID: nil as UUID?, userID: ownerID)
        let folderID = try folder.requireID()

        let share = InternalShare(fileID: folderID, granteeType: .user, granteeUserID: collaboratorID, role: .editor, createdBy: ownerID)
        try await share.save(on: app.db)

        let session = try await files.uploads.initiateMultipartUpload(
            filename: "uploaded.txt",
            contentType: "text/plain",
            totalSize: 11,
            parentID: folderID,
            lastModified: nil,
            userID: collaboratorID,
            maxChunkSize: Int64(app.config.maxChunkSize.value)
        )

        // Target owner must be the folder owner (Alice), not the uploader (Bob)
        XCTAssertEqual(session.userID, ownerID)

        let partRequest = Request(
            application: app,
            collectedBody: ByteBuffer(string: "Hello World"),
            on: app.eventLoopGroup.next()
        )
        let completedPart = try await files.uploads.uploadPart(
            fileID: session.fileID,
            uploadID: session.uploadID,
            partNumber: 1,
            userID: session.userID,
            stream: partRequest.body,
            size: 11
        )

        let completed = try await files.uploads.completeMultipartUpload(
            sessionID: session.sessionID,
            fileID: session.fileID,
            uploadID: session.uploadID,
            userID: session.userID,
            filename: session.filename,
            contentType: session.contentType,
            totalSize: session.totalSize,
            parentID: session.parentID,
            lastModified: session.lastModified,
            parts: [completedPart]
        )

        XCTAssertEqual(completed.$owner.id, ownerID)
        XCTAssertEqual(completed.$parent.id, folderID)
        XCTAssertEqual(completed.filename, "uploaded.txt")
    }

    func testSharedFolderBreadcrumbScoping() async throws {
        let root = try await files.files.createDirectory(name: "RootPrivate", parentID: nil as UUID?, userID: ownerID)
        let rootID = try root.requireID()

        let folderA = try await files.files.createDirectory(name: "SharedProject", parentID: rootID, userID: ownerID)
        let folderAID = try folderA.requireID()

        let folderB = try await files.files.createDirectory(name: "SubFolder", parentID: folderAID, userID: ownerID)
        let folderBID = try folderB.requireID()

        let share = InternalShare(fileID: folderAID, granteeType: .user, granteeUserID: collaboratorID, role: .viewer, createdBy: ownerID)
        try await share.save(on: app.db)

        let index = try await files.listing.list(filter: .folder(id: folderBID), userID: collaboratorID)
        let crumbs = index.breadcrumbs

        // Should start with Shared with me, then SharedProject, then SubFolder (RootPrivate must NOT be visible)
        XCTAssertEqual(crumbs.count, 3)
        XCTAssertEqual(crumbs[0].name, "Shared with me")
        XCTAssertEqual(crumbs[1].name, "SharedProject")
        XCTAssertEqual(crumbs[2].name, "SubFolder")
    }

    func testSharedWithOthersFilter() async throws {
        let folder = try await files.files.createDirectory(name: "MySharedFolder", parentID: nil, userID: ownerID)
        let folderID = try folder.requireID()

        let privateFolder = try await files.files.createDirectory(name: "PrivateFolder", parentID: nil, userID: ownerID)
        _ = try privateFolder.requireID()

        var sharedList = try await files.listing.list(filter: .sharedWithOthers, userID: ownerID)
        XCTAssertEqual(sharedList.files.count, 0)
        XCTAssertEqual(sharedList.breadcrumbs.first?.name, "Shared with others")

        let share = InternalShare(fileID: folderID, granteeType: .user, granteeUserID: collaboratorID, role: .viewer, createdBy: ownerID)
        try await share.save(on: app.db)
        folder.isShared = true
        try await folder.save(on: app.db)

        // After sharing, owner sees MySharedFolder in sharedWithOthers
        sharedList = try await files.listing.list(filter: .sharedWithOthers, userID: ownerID)
        XCTAssertEqual(sharedList.files.count, 1)
        XCTAssertEqual(sharedList.files.first?.filename, "MySharedFolder")

        // Collaborator sees nothing in sharedWithOthers (since collaborator did not share anything)
        let collaboratorList = try await files.listing.list(filter: .sharedWithOthers, userID: collaboratorID)
        XCTAssertEqual(collaboratorList.files.count, 0)

        // Collaborator sees it in shared (shared with me)
        let collaboratorSharedWithMe = try await files.listing.list(filter: .shared, userID: collaboratorID)
        XCTAssertEqual(collaboratorSharedWithMe.files.count, 1)
        XCTAssertEqual(collaboratorSharedWithMe.files.first?.filename, "MySharedFolder")

        // If collaborator (manager) shares with Charlie, collaborator now sees MySharedFolder in sharedWithOthers too
        let managerShare = InternalShare(fileID: folderID, granteeType: .user, granteeUserID: groupUser1ID, role: .viewer, createdBy: collaboratorID)
        try await managerShare.save(on: app.db)

        let collaboratorSharedWithOthers = try await files.listing.list(filter: .sharedWithOthers, userID: collaboratorID)
        XCTAssertEqual(collaboratorSharedWithOthers.files.count, 1)
        XCTAssertEqual(collaboratorSharedWithOthers.files.first?.filename, "MySharedFolder")
    }

    func testAllUsersVirtualGroupFileSharing() async throws {
        guard let allUsersGroup = try await Group.query(on: app.db).filter(\.$systemKey == "all_users").first() else {
            XCTFail("All Users system group should exist")
            return
        }
        let allUsersGroupID = try allUsersGroup.requireID()

        let file = try await files.files.createFile(name: "AllCompanyDoc", type: .text, parentID: nil as UUID?, userID: ownerID)
        let fileID = try file.requireID()

        do {
            _ = try await files.access.validateAccess(fileID: fileID, userID: collaboratorID, required: .read)
            XCTFail("Collaborator should not have access before share")
        } catch {}

        let share = InternalShare(fileID: fileID, granteeType: .group, granteeGroupID: allUsersGroupID, role: .editor, createdBy: ownerID)
        try await share.save(on: app.db)
        file.isShared = true
        try await file.save(on: app.db)

        // Collaborator (Bob), Charlie, and Dave should all have write & read access
        let bobAccess = try await files.access.validateAccess(fileID: fileID, userID: collaboratorID, required: .write)
        XCTAssertTrue(bobAccess.canRead)
        XCTAssertTrue(bobAccess.canWrite)
        XCTAssertEqual(bobAccess.ownerID, ownerID)

        let charlieAccess = try await files.access.validateAccess(fileID: fileID, userID: groupUser1ID, required: .read)
        XCTAssertTrue(charlieAccess.canRead)

        let daveAccess = try await files.access.validateAccess(fileID: fileID, userID: groupUser2ID, required: .read)
        XCTAssertTrue(daveAccess.canRead)

        let downloadResponse = try await files.files.getDownloadResponse(fileID: fileID, userID: collaboratorID)
        XCTAssertEqual(downloadResponse.status, .ok)

        // Collaborator sees the file in "Shared with me"
        let bobShared = try await files.listing.list(filter: .shared, userID: collaboratorID)
        XCTAssertEqual(bobShared.files.count, 1)
        XCTAssertEqual(bobShared.files.first?.filename, "AllCompanyDoc.txt")
        XCTAssertEqual(bobShared.files.first?.permissions?.canWrite, true)

        // Owner does NOT see the file in "Shared with me" (it's their own file)
        let ownerShared = try await files.listing.list(filter: .shared, userID: ownerID)
        XCTAssertEqual(ownerShared.files.count, 0)

        // Owner sees the file in "Shared with others"
        let ownerSharedWithOthers = try await files.listing.list(filter: .sharedWithOthers, userID: ownerID)
        XCTAssertEqual(ownerSharedWithOthers.files.count, 1)
        XCTAssertEqual(ownerSharedWithOthers.files.first?.filename, "AllCompanyDoc.txt")
    }

    func testAllUsersVirtualGroupFolderSharingAndBreadcrumbs() async throws {
        guard let allUsersGroup = try await Group.query(on: app.db).filter(\.$systemKey == "all_users").first() else {
            XCTFail("All Users system group should exist")
            return
        }
        let allUsersGroupID = try allUsersGroup.requireID()

        let rootFolder = try await files.files.createDirectory(name: "CompanyPublic", parentID: nil as UUID?, userID: ownerID)
        let rootFolderID = try rootFolder.requireID()

        let subFolder = try await files.files.createDirectory(name: "SubDocs", parentID: rootFolderID, userID: ownerID)
        let subFolderID = try subFolder.requireID()

        let childFile = try await files.files.createFile(name: "Handbook", type: .text, parentID: subFolderID, userID: ownerID)
        let childFileID = try childFile.requireID()

        let share = InternalShare(fileID: rootFolderID, granteeType: .group, granteeGroupID: allUsersGroupID, role: .viewer, createdBy: ownerID)
        try await share.save(on: app.db)
        rootFolder.isShared = true
        try await rootFolder.save(on: app.db)

        // Any user can read the child file and subfolder
        let bobSubAccess = try await files.access.validateAccess(fileID: subFolderID, userID: collaboratorID, required: .read)
        XCTAssertTrue(bobSubAccess.canRead)
        XCTAssertFalse(bobSubAccess.canWrite)

        let bobFileAccess = try await files.access.validateAccess(fileID: childFileID, userID: collaboratorID, required: .read)
        XCTAssertTrue(bobFileAccess.canRead)
        XCTAssertFalse(bobFileAccess.canWrite)

        do {
            _ = try await files.access.validateAccess(fileID: subFolderID, userID: collaboratorID, required: .write)
            XCTFail("Viewer should not have write access")
        } catch {}

        // Collaborator navigates to SubDocs: breadcrumbs should be properly scoped
        let subFolderIndex = try await files.listing.list(filter: .folder(id: subFolderID), userID: collaboratorID)
        let crumbs = subFolderIndex.breadcrumbs
        XCTAssertEqual(crumbs.count, 3)
        XCTAssertEqual(crumbs[0].name, "Shared with me")
        XCTAssertEqual(crumbs[1].name, "CompanyPublic")
        XCTAssertEqual(crumbs[2].name, "SubDocs")
    }

    func testAllUsersRoleUpgradeViaDirectShare() async throws {
        guard let allUsersGroup = try await Group.query(on: app.db).filter(\.$systemKey == "all_users").first() else {
            XCTFail("All Users system group should exist")
            return
        }
        let allUsersGroupID = try allUsersGroup.requireID()

        let file = try await files.files.createFile(name: "Strategy", type: .document, parentID: nil as UUID?, userID: ownerID)
        let fileID = try file.requireID()

        let allUsersShare = InternalShare(fileID: fileID, granteeType: .group, granteeGroupID: allUsersGroupID, role: .viewer, createdBy: ownerID)
        try await allUsersShare.save(on: app.db)

        let directShare = InternalShare(fileID: fileID, granteeType: .user, granteeUserID: groupUser1ID, role: .editor, createdBy: ownerID)
        try await directShare.save(on: app.db)

        // Charlie gets Editor (max(viewer, editor) == editor)
        let charlieAccess = try await files.access.validateAccess(fileID: fileID, userID: groupUser1ID, required: .write)
        XCTAssertTrue(charlieAccess.canWrite)

        // Bob (All Users only) gets Viewer (no write access)
        let bobAccess = try await files.access.validateAccess(fileID: fileID, userID: collaboratorID, required: .read)
        XCTAssertTrue(bobAccess.canRead)
        XCTAssertFalse(bobAccess.canWrite)
    }

    func testMoveWithinSharedFolderSucceeds() async throws {
        let projectFolder = try await files.files.createDirectory(name: "Projects", parentID: nil as UUID?, userID: ownerID)
        let projectFolderID = try projectFolder.requireID()

        let folderA = try await files.files.createDirectory(name: "FolderA", parentID: projectFolderID, userID: ownerID)
        let folderAID = try folderA.requireID()

        let folderB = try await files.files.createDirectory(name: "FolderB", parentID: projectFolderID, userID: ownerID)
        let folderBID = try folderB.requireID()

        let doc = try await files.files.createFile(name: "Notes", type: .text, parentID: folderAID, userID: ownerID)
        let docID = try doc.requireID()

        let share = InternalShare(fileID: projectFolderID, granteeType: .user, granteeUserID: collaboratorID, role: .editor, createdBy: ownerID)
        try await share.save(on: app.db)

        // Bob moves Notes from FolderA to FolderB (same owner)
        let movedDoc = try await files.files.move(fileID: docID, newParentID: folderBID, userID: collaboratorID)
        XCTAssertEqual(movedDoc.$parent.id, folderBID)
        XCTAssertEqual(movedDoc.$owner.id, ownerID)
    }

    func testMoveSharedItemToPersonalAccountFails() async throws {
        let projectFolder = try await files.files.createDirectory(name: "SharedProjects", parentID: nil as UUID?, userID: ownerID)
        let projectFolderID = try projectFolder.requireID()

        let doc = try await files.files.createFile(name: "Spec", type: .document, parentID: projectFolderID, userID: ownerID)
        let docID = try doc.requireID()

        let bobPersonalFolder = try await files.files.createDirectory(name: "BobPrivate", parentID: nil as UUID?, userID: collaboratorID)
        let bobPersonalFolderID = try bobPersonalFolder.requireID()

        let share = InternalShare(fileID: projectFolderID, granteeType: .user, granteeUserID: collaboratorID, role: .editor, createdBy: ownerID)
        try await share.save(on: app.db)

        // Attempt 1: Bob moves Spec to his personal folder (cross-owner move)
        do {
            _ = try await files.files.move(fileID: docID, newParentID: bobPersonalFolderID, userID: collaboratorID)
            XCTFail("Moving shared item into personal folder should be forbidden")
        } catch let abort as any AbortError {
            XCTAssertEqual(abort.status, .forbidden)
        }

        // Attempt 2: Bob moves Spec to his personal root (newParentID == nil)
        do {
            _ = try await files.files.move(fileID: docID, newParentID: nil, userID: collaboratorID)
            XCTFail("Moving shared item to personal root should be forbidden")
        } catch let abort as any AbortError {
            XCTAssertEqual(abort.status, .forbidden)
        }
    }
}


