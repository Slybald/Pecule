import CryptoKit
import Foundation
import SwiftData
import XCTest
@testable import Pecule

// Un store plus récent que l'app, ou qu'aucune version connue : le cas d'un ancien binaire devant un store V6.
@Model
private final class UnknownSchemaFixture {
    var name: String
    init(name: String) { self.name = name }
}

// Vrais fichiers dans un répertoire temporaire : la copie avant migration est une promesse sur des octets,
// qu'une base en mémoire ne permettrait pas de vérifier.
@MainActor
final class StoreBackupTests: XCTestCase {
    private enum Refusal: Error { case refused }

    // MARK: - Copie avant migration

    // (a) Une base d'une version antérieure : copie des fichiers présents, ouverture réussie, repère écrit.
    func testOpeningAnOlderStoreCopiesItsFilesFirstThenOpensAndWritesTheMarker() throws {
        let directory = try makeDirectory()
        let url = directory.appending(path: "LifeOS.store")
        let purchaseID = UUID()
        try makeV1Store(at: url, purchaseID: purchaseID)
        let present = ["LifeOS.store", "LifeOS.store-wal", "LifeOS.store-shm"]
        XCTAssertEqual(try existingNames(present, in: directory), present, "la fixture doit ressembler à une app tuée en cours d'écriture : journal et index présents")
        let before = try snapshot(of: directory)
        XCTAssertEqual(before.keys.sorted(), present.sorted())

        let clock = SteppingClock(start: TestFixtures.referenceDate)
        let opener = PersistentStoreOpener(now: { clock.now() })
        try autoreleasepool {
            let container = try opener.open(configuration(url))
            let purchase = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<Purchase>()).first)
            XCTAssertEqual(purchase.id, purchaseID)
            XCTAssertEqual(purchase.notes, "Keep this annotation")
        }

        let backups = opener.backupFolders(of: .init(storeURL: url))
        XCTAssertEqual(backups.map(\.lastPathComponent), ["20260914T073422Z-inconnue"], "horodatage UTC de l'horloge injectée, version non lue")
        let backup = try XCTUnwrap(backups.first)
        // Octet pour octet l'état d'AVANT l'ouverture, alors que l'ouverture a migré la base en place.
        XCTAssertEqual(try snapshot(of: backup), before)
        XCTAssertNotEqual(try snapshot(of: directory), before, "l'ouverture a bien modifié les fichiers d'origine (migration en place) : la copie était nécessaire")
        XCTAssertEqual(try String(contentsOf: directory.appending(path: "LifeOS.store.version"), encoding: .utf8), expectedVersion)
        XCTAssertEqual(try excluded(backup), true)
        XCTAssertEqual(try excluded(directory.appending(path: "Backups")), true)
    }

    // (b) Un repère à jour : plus aucune copie, pas même une tentative.
    func testReopeningWithAnUpToDateMarkerCreatesNoCopy() throws {
        let directory = try makeDirectory()
        let url = directory.appending(path: "LifeOS.store")
        try makeV1Store(at: url, purchaseID: UUID())
        let clock = SteppingClock(start: TestFixtures.referenceDate)
        let opener = PersistentStoreOpener(now: { clock.now() })
        try autoreleasepool { _ = try opener.open(configuration(url)) }
        XCTAssertEqual(opener.backupFolders(of: .init(storeURL: url)).count, 1)

        // Sans le dossier, une seconde copie réapparaîtrait : on prouve ainsi qu'aucune n'est même tentée.
        try FileManager.default.removeItem(at: directory.appending(path: "Backups"))
        for _ in 0..<2 {
            try autoreleasepool {
                let container = try opener.open(configuration(url))
                XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<Purchase>()).count, 1)
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(path: "Backups").path))
        XCTAssertEqual(try String(contentsOf: directory.appending(path: "LifeOS.store.version"), encoding: .utf8), expectedVersion)
    }

    // (c) Fichier corrompu : l'ouverture échoue, la base d'origine reste identique à l'octet, la copie existe.
    func testCorruptedStoreFailsToOpenLeavesTheOriginalByteIdenticalAndKeepsACopy() throws {
        let directory = try makeDirectory()
        let url = directory.appending(path: "LifeOS.store")
        try Data((0..<8192).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }).write(to: url)
        let before = try sha256(url)

        let opener = PersistentStoreOpener(now: { TestFixtures.referenceDate })
        XCTAssertThrowsError(try opener.open(configuration(url))) { error in
            guard let failure = error as? StoreOpenError else { return XCTFail("une erreur récupérable était attendue, pas \(error)") }
            XCTAssertEqual(failure.stage, .open)
            XCTAssertTrue(failure.hasBackup)
            XCTAssertTrue(failure.identifier.hasPrefix("open-"), failure.identifier)
            XCTAssertEqual(failure.messageKey, "storage.recovery.message.copyKept")
        }

        XCTAssertEqual(try sha256(url), before, "la base d'origine n'a pas bougé d'un octet")
        // Ni base de remplacement ni fichier mis de côté : seuls peuvent apparaître le journal et son index.
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)).subtracting(["LifeOS.store-wal", "LifeOS.store-shm"]), ["Backups", "LifeOS.store"])
        let backups = opener.backupFolders(of: .init(storeURL: url))
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try sha256(backups[0].appending(path: "LifeOS.store")), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(path: "LifeOS.store.version").path), "pas de repère après un échec")

        // « Réessayer » sur une base qui n'a pas changé ne refait pas de copie : trois essais ne doivent
        // pas suffire à chasser la copie d'origine.
        XCTAssertThrowsError(try opener.open(configuration(url)))
        XCTAssertThrowsError(try opener.open(configuration(url)))
        XCTAssertEqual(opener.backupFolders(of: .init(storeURL: url)).count, 1)
        XCTAssertEqual(try sha256(url), before)
    }

    // (c bis) Schéma inconnu, comme un store V7 devant un binaire V6 : mêmes garanties, sans corruption.
    func testStoreFromAnUnknownSchemaFailsToOpenWithoutChangingTheOriginal() throws {
        let directory = try makeDirectory()
        let url = directory.appending(path: "LifeOS.store")
        try autoreleasepool {
            let schema = Schema([UnknownSchemaFixture.self])
            let container = try ModelContainer(for: schema, configurations: [ModelConfiguration("LifeOS", schema: schema, url: url)])
            container.mainContext.insert(UnknownSchemaFixture(name: "from the future"))
            try container.mainContext.save()
        }
        let before = try snapshot(of: directory)

        let opener = PersistentStoreOpener(now: { TestFixtures.referenceDate })
        XCTAssertThrowsError(try opener.open(configuration(url))) { error in
            guard let failure = error as? StoreOpenError else { return XCTFail("une erreur récupérable était attendue, pas \(error)") }
            XCTAssertEqual(failure.stage, .open)
            XCTAssertTrue(failure.hasBackup)
        }

        // Le `-shm` n'est qu'un index que SQLite réécrit à chaque ouverture, même ratée : observé ici, base et
        // journal identiques à l'octet, index différent. Il ne compte donc pas parmi les données.
        XCTAssertEqual(try snapshot(of: directory).filter { !$0.key.hasSuffix("-shm") }, before.filter { !$0.key.hasSuffix("-shm") }, "ni la base ni son journal n'ont changé, aucun fichier n'est apparu ou disparu")
        XCTAssertEqual(Set(try snapshot(of: directory).keys), Set(before.keys))
        let backup = try XCTUnwrap(opener.backupFolders(of: .init(storeURL: url)).first)
        XCTAssertEqual(try snapshot(of: backup), before, "la copie, faite avant l'ouverture, est identique à tous les fichiers d'origine")

        // Même scénario qu'un « Réessayer » : l'index a changé, pas les données, donc pas de seconde copie.
        XCTAssertThrowsError(try opener.open(configuration(url))) { error in
            // SwiftData ne remonte pas la cause (Core Data la journalise seulement : 134504 ici, 259 pour un
            // fichier corrompu) : observé, les deux échecs donnent SwiftDataError code 1.
            XCTAssertTrue((error as? StoreOpenError)?.identifier.hasPrefix("open-") == true)
        }
        XCTAssertThrowsError(try opener.open(configuration(url)))
        XCTAssertEqual(opener.backupFolders(of: .init(storeURL: url)).count, 1)
    }

    // (d) Une base en mémoire ou absente : aucune copie.
    func testInMemoryAndAbsentStoresCreateNoCopy() throws {
        let recorder = RecordingFileManager()
        let inMemory = try PersistentStoreOpener(fileManager: recorder).open(ModelConfiguration(schema: PeculeSchema.current, isStoredInMemoryOnly: true))
        XCTAssertTrue(try inMemory.mainContext.fetch(FetchDescriptor<Purchase>()).isEmpty)
        XCTAssertEqual(recorder.calls, [], "une base en mémoire ne touche à aucun fichier : ni copie, ni repère")

        let directory = try makeDirectory()
        let url = directory.appending(path: "LifeOS.store")
        try autoreleasepool { _ = try PersistentStoreOpener().open(configuration(url)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "la base est créée")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(path: "Backups").path), "mais rien n'était à copier")
        XCTAssertEqual(try String(contentsOf: directory.appending(path: "LifeOS.store.version"), encoding: .utf8), expectedVersion, "et le repère dit dès maintenant à quelle version elle est née")
    }

    // (e) Au plus trois copies, les plus récentes ; ce qui n'est pas à nous n'est jamais supprimé.
    func testAtMostThreeCopiesAreKeptAndForeignFoldersAreLeftAlone() throws {
        let directory = try makeDirectory()
        let url = directory.appending(path: "LifeOS.store")
        let foreign = directory.appending(path: "Backups/notes-de-nicolas")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        let clock = SteppingClock(start: TestFixtures.referenceDate)
        let opener = PersistentStoreOpener(now: { clock.now() })

        for generation in 0..<5 {
            // La base change entre deux tentatives, sinon la copie précédente serait reprise.
            try Data("generation \(generation)".utf8).write(to: url)
            XCTAssertThrowsError(try opener.open(configuration(url), makeContainer: { _ in throw Refusal.refused }))
        }

        let backups = opener.backupFolders(of: .init(storeURL: url)).reversed()
        XCTAssertEqual(try backups.map { try String(contentsOf: $0.appending(path: "LifeOS.store"), encoding: .utf8) }, ["generation 2", "generation 3", "generation 4"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path))
    }

    // (c ter) Base déjà installée (repère « 6.0.0 » à jour) dont l'ouverture échoue : le cas d'une propriété
    // ajoutée à un modèle vivant sans V7. Aucune copie n'est faite avant, une est faite juste après l'échec.
    func testFailedOpenWithAnUpToDateMarkerStillKeepsACopyMarkedAsFailed() throws {
        let directory = try makeDirectory()
        let url = directory.appending(path: "LifeOS.store")
        try Data((0..<8192).map { UInt8(truncatingIfNeeded: $0 &* 17 &+ 3) }).write(to: url)
        try Data(expectedVersion.utf8).write(to: directory.appending(path: "LifeOS.store.version"))
        try Data("journal".utf8).write(to: directory.appending(path: "LifeOS.store-wal"))
        try Data("index".utf8).write(to: directory.appending(path: "LifeOS.store-shm"))
        let before = try sha256(url)

        let opener = PersistentStoreOpener(now: { TestFixtures.referenceDate })
        XCTAssertThrowsError(try opener.open(configuration(url))) { error in
            guard let failure = error as? StoreOpenError else { return XCTFail("une erreur récupérable était attendue, pas \(error)") }
            XCTAssertEqual(failure.stage, .open)
            XCTAssertTrue(failure.hasBackup)
            XCTAssertEqual(failure.messageKey, "storage.recovery.message.copyKept")
        }
        let backups = opener.backupFolders(of: .init(storeURL: url))
        XCTAssertEqual(backups.count, 1)
        XCTAssertTrue(PersistentStoreOpener.isFailedOpenCopy(backups[0].lastPathComponent), backups[0].lastPathComponent)
        XCTAssertEqual(try sha256(backups[0].appending(path: "LifeOS.store")), before)
        XCTAssertEqual(try String(contentsOf: backups[0].appending(path: "LifeOS.store-wal"), encoding: .utf8), "journal", "le journal -wal est copié aussi")
        XCTAssertEqual(try String(contentsOf: backups[0].appending(path: "LifeOS.store-shm"), encoding: .utf8), "index", "l'index -shm aussi")
        XCTAssertEqual(try sha256(url), before, "la base d'origine n'a pas bougé d'un octet")

        // « Réessayer » ne refait pas de copie tant que la base ne change pas.
        XCTAssertThrowsError(try opener.open(configuration(url)))
        XCTAssertEqual(opener.backupFolders(of: .init(storeURL: url)).count, 1)
    }

    // Les copies faites après un échec viennent d'une base suspecte : elles suivent la rotation de trois,
    // mais ne chassent jamais la dernière copie saine.
    func testCopiesMadeAfterFailedOpensNeverRotateTheLastHealthyCopyOut() throws {
        let directory = try makeDirectory()
        let url = directory.appending(path: "LifeOS.store")
        let healthy = directory.appending(path: "Backups/20200101T000000Z-5.0.0")
        try FileManager.default.createDirectory(at: healthy, withIntermediateDirectories: true)
        try Data("healthy".utf8).write(to: healthy.appending(path: "LifeOS.store"))
        try Data(expectedVersion.utf8).write(to: directory.appending(path: "LifeOS.store.version"))
        let clock = SteppingClock(start: TestFixtures.referenceDate)
        let opener = PersistentStoreOpener(now: { clock.now() })

        for generation in 0..<5 {
            try Data("unreadable \(generation)".utf8).write(to: url)
            XCTAssertThrowsError(try opener.open(configuration(url), makeContainer: { _ in throw Refusal.refused }))
        }

        let names = opener.backupFolders(of: .init(storeURL: url)).map(\.lastPathComponent)
        XCTAssertEqual(names.count, 3)
        XCTAssertTrue(names.contains("20200101T000000Z-5.0.0"), "la copie saine est gardée : \(names)")
        let latest = try XCTUnwrap(opener.backupFolders(of: .init(storeURL: url)).first)
        XCTAssertEqual(try String(contentsOf: latest.appending(path: "LifeOS.store"), encoding: .utf8), "unreadable 4")
        XCTAssertEqual(try String(contentsOf: healthy.appending(path: "LifeOS.store"), encoding: .utf8), "healthy")
    }

    // Une copie qui échoue après l'échec d'ouverture ne masque pas l'erreur d'ouverture, et ne laisse rien.
    func testAnImpossibleCopyAfterAFailedOpenKeepsTheOpenErrorAndNoHalfCopy() throws {
        let directory = try makeDirectory()
        let url = directory.appending(path: "LifeOS.store")
        try Data("base".utf8).write(to: url)
        try Data(expectedVersion.utf8).write(to: directory.appending(path: "LifeOS.store.version"))
        let opener = PersistentStoreOpener(fileManager: CopyRefusingFileManager())
        XCTAssertThrowsError(try opener.open(configuration(url), makeContainer: { _ in throw Refusal.refused })) { error in
            guard let failure = error as? StoreOpenError else { return XCTFail("une erreur récupérable était attendue, pas \(error)") }
            XCTAssertEqual(failure.stage, .open)
            XCTAssertFalse(failure.hasBackup)
            XCTAssertEqual(failure.messageKey, "storage.recovery.message.noCopy")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.appending(path: "Backups").path), [])
    }

    // (f) Une copie impossible empêche l'ouverture : on ne migre jamais sans filet.
    func testAnImpossibleCopyPreventsOpeningTheStore() throws {
        let directory = try makeDirectory()
        let url = directory.appending(path: "LifeOS.store")
        try makeV1Store(at: url, purchaseID: UUID())
        let before = try snapshot(of: directory)
        XCTAssertFalse(before.isEmpty)

        var openingAttempts = 0
        let opener = PersistentStoreOpener(fileManager: CopyRefusingFileManager())
        XCTAssertThrowsError(try opener.open(configuration(url), makeContainer: { configuration in
            openingAttempts += 1
            return try PersistentStoreOpener.makePeculeContainer(configuration)
        })) { error in
            guard let failure = error as? StoreOpenError else { return XCTFail("une erreur récupérable était attendue, pas \(error)") }
            XCTAssertEqual(failure.stage, .backup)
            XCTAssertFalse(failure.hasBackup)
            XCTAssertEqual(failure.identifier, "backup-NSCocoaErrorDomain-640")
            XCTAssertEqual(failure.messageKey, "storage.recovery.message.backupFailed")
        }

        XCTAssertEqual(openingAttempts, 0, "la base n'a même pas été ouverte")
        XCTAssertEqual(try snapshot(of: directory), before, "ouverte, cette base V1 aurait été migrée en place : elle est intacte")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(path: "LifeOS.store.version").path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.appending(path: "Backups").path)
        XCTAssertEqual(leftovers, [], "pas de copie à moitié écrite, qui prendrait la place d'une bonne")
    }

    // MARK: - Garde-fous autour de la copie

    func testRetryingAFailedOpenDoesNotRotateTheOriginalCopyOut() throws {
        let directory = try makeDirectory()
        let url = directory.appending(path: "LifeOS.store")
        try Data("original".utf8).write(to: url)
        let clock = SteppingClock(start: TestFixtures.referenceDate)
        let opener = PersistentStoreOpener(now: { clock.now() })
        for _ in 0..<6 {
            XCTAssertThrowsError(try opener.open(configuration(url), makeContainer: { _ in throw Refusal.refused }))
        }
        let backups = opener.backupFolders(of: .init(storeURL: url))
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try String(contentsOf: backups[0].appending(path: "LifeOS.store"), encoding: .utf8), "original")
    }

    func testAFreshCopyIsNeverPrunedEvenWhenTheClockRunsBackwards() throws {
        let directory = try makeDirectory()
        let url = directory.appending(path: "LifeOS.store")
        try Data("now".utf8).write(to: url)
        for stamp in ["20300101T000000Z-6.0.0", "20300102T000000Z-6.0.0", "20300103T000000Z-6.0.0"] {
            let folder = directory.appending(path: "Backups/\(stamp)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(stamp.utf8).write(to: folder.appending(path: "LifeOS.store"))
        }
        let opener = PersistentStoreOpener(now: { TestFixtures.referenceDate })
        XCTAssertThrowsError(try opener.open(configuration(url), makeContainer: { _ in throw Refusal.refused }))

        let names = opener.backupFolders(of: .init(storeURL: url)).map(\.lastPathComponent)
        XCTAssertEqual(names, ["20300103T000000Z-6.0.0", "20300102T000000Z-6.0.0", "20260914T073422Z-inconnue"])
    }

    func testFolderNameCarriesTheVersionReadAndIgnoresAnUnsafeMarker() throws {
        let directory = try makeDirectory()
        let url = directory.appending(path: "LifeOS.store")
        let marker = directory.appending(path: "LifeOS.store.version")
        let opener = PersistentStoreOpener(now: { TestFixtures.referenceDate })
        try Data("original".utf8).write(to: url)

        try Data("5.0.0\n".utf8).write(to: marker)
        XCTAssertThrowsError(try opener.open(configuration(url), makeContainer: { _ in throw Refusal.refused }))
        XCTAssertEqual(opener.backupFolders(of: .init(storeURL: url)).map(\.lastPathComponent), ["20260914T073422Z-5.0.0"])

        try Data("changed".utf8).write(to: url)
        try Data("../../evil/6".utf8).write(to: marker)
        XCTAssertThrowsError(try opener.open(configuration(url), makeContainer: { _ in throw Refusal.refused }))
        XCTAssertEqual(opener.backupFolders(of: .init(storeURL: url)).map(\.lastPathComponent), ["20260914T073422Z-inconnue", "20260914T073422Z-5.0.0"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), ["Backups", "LifeOS.store", "LifeOS.store.version"])
    }

    func testProfileStoresKeepTheirCopiesBesideTheirOwnStore() throws {
        let root = try makeDirectory()
        let issuer = URL(string: "https://gateway.test")!
        let alice = ProfileStoreLocation(issuer: issuer, userID: "alice")
        let bob = ProfileStoreLocation(issuer: issuer, userID: "bob")
        let aliceURL = alice.storeURL(root: root)
        try FileManager.default.createDirectory(at: aliceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makeV1Store(at: aliceURL, purchaseID: UUID())
        let clock = SteppingClock(start: TestFixtures.referenceDate)

        try autoreleasepool { _ = try PeculeDataStore.makeProfileContainer(location: alice, root: root, opener: PersistentStoreOpener(now: { clock.now() })) }
        try autoreleasepool { _ = try PeculeDataStore.makeProfileContainer(location: bob, root: root, opener: PersistentStoreOpener(now: { clock.now() })) }

        let aliceBackups = aliceURL.deletingLastPathComponent().appending(path: "Backups")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: aliceBackups.path).count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bob.storeURL(root: root).deletingLastPathComponent().appending(path: "Backups").path), "une base neuve n'a rien à copier")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "Backups").path))
    }

    // MARK: - Version, horodatage, erreur

    func testMarkerVersionComesFromTheCurrentSchemaAndTimestampsAreUTCWithoutColons() {
        let last = PeculeMigrationPlan.schemas.last?.versionIdentifier
        XCTAssertEqual(PersistentStoreOpener.currentSchemaVersion, last.map { "\($0.major).\($0.minor).\($0.patch)" })
        XCTAssertEqual(PeculeSchema.current.version, last, "le schéma courant et le dernier du plan de migration doivent rester d'accord")
        // 2026-09-14T07:34:22Z, en toutes lettres plutôt que recalculé.
        XCTAssertEqual(PersistentStoreOpener.timestamp(TestFixtures.referenceDate), "20260914T073422Z")
        XCTAssertTrue(PersistentStoreOpener.isBackupFolderName("20260914T073422Z-inconnue"))
        XCTAssertTrue(PersistentStoreOpener.isBackupFolderName("20260914T073422Z-6.0.0-2"))
        XCTAssertFalse(PersistentStoreOpener.isBackupFolderName("notes-de-nicolas"))
        XCTAssertFalse(PersistentStoreOpener.isBackupFolderName(".staging-20260914T073422Z-6.0.0"))
    }

    func testRecoveryMessagesDependOnWhatReallyHappenedAndExistInFrenchAndEnglish() throws {
        let corrupt = CocoaError(.fileReadCorruptFile)
        let folder = URL(fileURLWithPath: "/tmp/copie")
        let kept = StoreOpenError(stage: .open, underlying: corrupt, backup: folder)
        let none = StoreOpenError(stage: .open, underlying: corrupt, backup: nil)
        let failed = StoreOpenError(stage: .backup, underlying: CocoaError(.fileWriteOutOfSpace), backup: nil)
        XCTAssertEqual(kept.messageKey, "storage.recovery.message.copyKept")
        XCTAssertEqual(none.messageKey, "storage.recovery.message.noCopy", "jamais « une copie existe » quand aucune n'a été faite")
        XCTAssertEqual(failed.messageKey, "storage.recovery.message.backupFailed")
        XCTAssertEqual(kept.identifier, "open-NSCocoaErrorDomain-259")
        XCTAssertEqual(failed.identifier, "backup-NSCocoaErrorDomain-640")

        let french = Locale(identifier: "fr"), english = Locale(identifier: "en")
        for key in ["storage.recovery.title", "storage.recovery.retry"] + [kept, none, failed].map(\.messageKey) {
            XCTAssertNotEqual(AppLocalizer.string(key, locale: french), key, "fr manquant : \(key)")
            XCTAssertNotEqual(AppLocalizer.string(key, locale: english), key, "en manquant : \(key)")
            XCTAssertNotEqual(AppLocalizer.string(key, locale: french), AppLocalizer.string(key, locale: english), "fr et en identiques : \(key)")
        }
        XCTAssertEqual(AppLocalizer.string("storage.recovery.retry", locale: french), "Réessayer")
        XCTAssertEqual(AppLocalizer.format("storage.recovery.errorID %@", locale: french, "open-X-1"), "Identifiant de l’erreur : open-X-1")
        XCTAssertEqual(AppLocalizer.format("storage.recovery.errorID %@", locale: english, "open-X-1"), "Error ID: open-X-1")
        XCTAssertTrue(AppLocalizer.string(kept.messageKey, locale: french).contains("copie"))
        XCTAssertFalse(AppLocalizer.string(none.messageKey, locale: french).contains("copie de sécurité de vos données"))
    }

    // MARK: - Écran de reprise

    func testRuntimeShowsTheRecoveryStateInsteadOfFallingBackThenRetryOpensTheStore() throws {
        let savedStore = AppIntentSupport.dataStore, savedPolicy = AppIntentSupport.requiresActiveProfile
        defer { AppIntentSupport.dataStore = savedStore; AppIntentSupport.requiresActiveProfile = savedPolicy }
        var attempts = 0
        let automation = AppAutomationConfiguration.fromEnvironment(["PECULE_AUTOMATION_DATA_MODE": "empty"])
        let runtime = PeculeRuntime(automation: automation, gatewayURL: nil) {
            attempts += 1
            if attempts <= 2 { throw StoreOpenError(stage: .open, underlying: CocoaError(.fileReadCorruptFile), backup: URL(fileURLWithPath: "/tmp/copie")) }
            return try PeculeDataStore.makeInMemoryContainer()
        }
        // Ni base de secours en mémoire, ni application vide : l'écran de reprise, et rien d'autre.
        XCTAssertNil(runtime.appState)
        XCTAssertNil(runtime.container)
        XCTAssertEqual(runtime.storeFailure?.identifier, "open-NSCocoaErrorDomain-259")
        XCTAssertEqual(attempts, 1)

        runtime.retryOpeningStore()
        XCTAssertEqual(attempts, 2)
        XCTAssertNil(runtime.appState, "l'échec persiste : l'écran reste")
        XCTAssertNotNil(runtime.storeFailure)

        runtime.retryOpeningStore()
        XCTAssertEqual(attempts, 3)
        XCTAssertNotNil(runtime.appState)
        XCTAssertNotNil(runtime.container)
        XCTAssertNil(runtime.storeFailure)

        runtime.retryOpeningStore()
        XCTAssertEqual(attempts, 3, "rien à rouvrir une fois la base ouverte")
    }

    // La panne simulée ne doit jamais pouvoir toucher une vraie base : elle n'existe qu'avec la base en mémoire.
    func testSimulatedStoreFailureNeedsTheInMemoryStoreAndIsNeverOnByDefault() {
        let flag = ["PECULE_AUTOMATION_SIMULATE_STORE_FAILURE": "1"]
        XCTAssertFalse(AppAutomationConfiguration.inert.simulatesStoreFailure)
        XCTAssertFalse(AppAutomationConfiguration.fromEnvironment([:]).simulatesStoreFailure)
        XCTAssertFalse(AppAutomationConfiguration.fromEnvironment(flag).simulatesStoreFailure, "seul, le drapeau ne fait rien")
        XCTAssertFalse(AppAutomationConfiguration.fromEnvironment(["PECULE_AUTOMATION_DATA_MODE": "empty"]).simulatesStoreFailure)
        XCTAssertTrue(AppAutomationConfiguration.fromEnvironment(flag.merging(["PECULE_UI_TESTS_USE_IN_MEMORY_STORE": "1"]) { $1 }).simulatesStoreFailure)
    }

    // MARK: - Fixtures

    private var expectedVersion: String {
        let version = PeculeMigrationPlan.schemas.last?.versionIdentifier ?? Schema.Version(0, 0, 0)
        return "\(version.major).\(version.minor).\(version.patch)"
    }

    private func configuration(_ url: URL) -> ModelConfiguration {
        ModelConfiguration("LifeOS", schema: PeculeSchema.current, url: url)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    // La fixture V1 de PersistentMigrationTests, écrite avec le nom de configuration de la production. Les
    // fichiers sont recopiés pendant que le conteneur est encore ouvert : les lignes validées restent alors
    // dans le journal `-wal`, exactement comme après une app que iOS a tuée sans fermer sa base.
    private func makeV1Store(at url: URL, purchaseID: UUID) throws {
        let scratch = url.deletingLastPathComponent().appending(path: "scratch-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let source = scratch.appending(path: url.lastPathComponent)
        try autoreleasepool {
            let schema = Schema(versionedSchema: PeculeSchemaV1.self)
            let container = try ModelContainer(for: schema, configurations: [ModelConfiguration("LifeOS", schema: schema, url: source)])
            container.mainContext.insert(PeculeSchemaV1.Purchase(id: purchaseID, title: "Personal", amount: 74.86, date: TestFixtures.referenceDate, category: "Insurance", merchant: "Fixture", notes: "Keep this annotation"))
            try container.mainContext.save()
            for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: source.path + suffix) {
                try FileManager.default.copyItem(at: URL(fileURLWithPath: source.path + suffix), to: URL(fileURLWithPath: url.path + suffix))
            }
            withExtendedLifetime(container) {}
        }
    }

    private func existingNames(_ names: [String], in directory: URL) throws -> [String] {
        names.filter { FileManager.default.fileExists(atPath: directory.appending(path: $0).path) }
    }

    // Empreinte de chaque fichier d'un dossier (les sous-dossiers, dont Backups, sont ignorés). Comparer deux
    // instantanés vérifie aussi qu'aucun fichier n'est apparu ni n'a disparu.
    private func snapshot(of directory: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.appending(path: name).path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            result[name] = try sha256(directory.appending(path: name))
        }
        return result
    }

    private func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    private func excluded(_ url: URL) throws -> Bool? {
        try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
    }
}

// Une horloge qui avance d'une minute à chaque lecture : deux copies n'ont jamais le même nom.
private final class SteppingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(start: Date) { date = start }
    func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        defer { date = date.addingTimeInterval(60) }
        return date
    }
}

// Le disque plein, sans remplir le disque : seule la copie échoue, comme sur un appareil saturé.
private final class CopyRefusingFileManager: FileManager, @unchecked Sendable {
    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        throw CocoaError(.fileWriteOutOfSpace)
    }
}

private final class RecordingFileManager: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var calls: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
    private func record(_ call: String) { lock.lock(); recorded.append(call); lock.unlock() }

    override func fileExists(atPath path: String) -> Bool { record("fileExists"); return super.fileExists(atPath: path) }
    override func contents(atPath path: String) -> Data? { record("contents"); return super.contents(atPath: path) }
    override func createFile(atPath path: String, contents data: Data?, attributes attr: [FileAttributeKey: Any]? = nil) -> Bool {
        record("createFile"); return super.createFile(atPath: path, contents: data, attributes: attr)
    }
    override func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool, attributes: [FileAttributeKey: Any]? = nil) throws {
        record("createDirectory"); try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }
    override func copyItem(at srcURL: URL, to dstURL: URL) throws { record("copyItem"); try super.copyItem(at: srcURL, to: dstURL) }
}
