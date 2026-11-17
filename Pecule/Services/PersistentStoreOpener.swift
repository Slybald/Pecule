import Foundation
import SwiftData

// Ce que l'utilisateur voit quand la base sur disque ne s'ouvre pas. Rien dans ce fichier ne supprime,
// ne recrée ni n'écrase un fichier de la base : le pire résultat possible est cette erreur, affichée sur un
// écran de reprise avec un bouton « Réessayer », pendant que les fichiers restent exactement où ils sont.
struct StoreOpenError: LocalizedError, Sendable {
    enum Stage: String, Sendable {
        // La copie de sécurité n'a pas pu être faite : par prudence, la base n'a pas été ouverte du tout.
        case backup
        // SwiftData a refusé d'ouvrir (ou de migrer) la base.
        case open
    }

    let stage: Stage
    let underlying: any Error
    // Dossier de la copie faite (ou reprise, si identique) pour cette tentative. nil quand aucune n'était
    // nécessaire ou qu'elle a échoué : l'écran ne doit jamais prétendre qu'une copie existe quand ce n'est pas le cas.
    let backup: URL?

    var hasBackup: Bool { backup != nil }

    // Code court, stable et sans aucune donnée personnelle, que l'utilisateur peut citer : l'étape, puis le
    // domaine et le code de l'erreur (« backup-NSCocoaErrorDomain-640 » : disque plein). Limite : SwiftData
    // ne remonte pas la cause d'une ouverture ratée, tous ses échecs donnent « open-SwiftData.SwiftDataError-1 ».
    // La cause réelle (Core Data : 259 fichier corrompu, 134504 version de modèle inconnue) n'est que dans la console.
    var identifier: String {
        let error = underlying as NSError
        return "\(stage.rawValue)-\(error.domain)-\(error.code)"
    }

    var messageKey: String {
        switch stage {
        case .backup: "storage.recovery.message.backupFailed"
        case .open: hasBackup ? "storage.recovery.message.copyKept" : "storage.recovery.message.noCopy"
        }
    }

    var errorDescription: String? { AppLocalizer.string(messageKey) }
}

// Tout ce qui sépare « l'app veut sa base » de « SwiftData l'a ouverte » : copie avant migration,
// repère de version, erreur récupérable. C'est le seul endroit qui crée un ModelContainer.
//
// Pour une base existante sur disque, un petit fichier hors SwiftData (`LifeOS.store.version`) garde la
// version du schéma avec laquelle elle a été ouverte pour la dernière fois. S'il manque ou s'il diffère de
// la version courante, la base (`.store`, `-wal`, `-shm`) est copiée dans `Backups/<horodatage>-<version>/`
// AVANT d'ouvrir, puisque l'ouverture peut migrer en place, de façon irréversible. Le repère n'est écrit
// qu'après une ouverture réussie. Si la copie échoue, la base n'est pas ouverte.
//
// Quand le repère est à jour, aucune copie n'est faite avant : mais si l'ouverture échoue quand même (base
// abîmée, schéma vivant modifié sans nouvelle version), la base est copiée juste après l'échec, avec le
// suffixe `.echec` dans le nom du dossier. Cette copie-là vient d'une base suspecte : la rotation ne la
// laisse jamais chasser la dernière copie saine.
struct PersistentStoreOpener {
    typealias ContainerFactory = (ModelConfiguration) throws -> ModelContainer

    static let backupsFolderName = "Backups"
    static let unknownVersionLabel = "inconnue"
    // Suffixe d'une copie faite après un échec d'ouverture : la base copiée est suspecte, pas une copie saine.
    static let failedOpenSuffix = ".echec"
    static let defaultKeptBackups = 3
    private static let stagingPrefix = ".staging-"

    var fileManager: FileManager
    var now: @Sendable () -> Date
    // nil : version du schéma courant, lue seulement quand une base sur disque est réellement ouverte.
    var currentVersion: String?
    var keptBackups: Int

    init(
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() },
        currentVersion: String? = nil,
        keptBackups: Int = PersistentStoreOpener.defaultKeptBackups
    ) {
        self.fileManager = fileManager
        self.now = now
        self.currentVersion = currentVersion
        self.keptBackups = keptBackups
    }

    // Identifiant de version du schéma avec lequel la base est ouverte, par exemple « 6.0.0 ».
    static var currentSchemaVersion: String {
        let version = PeculeSchema.current.version
        return "\(version.major).\(version.minor).\(version.patch)"
    }

    static func makePeculeContainer(_ configuration: ModelConfiguration) throws -> ModelContainer {
        try ModelContainer(for: PeculeSchema.current, migrationPlan: PeculeMigrationPlan.self, configurations: [configuration])
    }

    func open(
        _ configuration: ModelConfiguration,
        makeContainer: ContainerFactory = PersistentStoreOpener.makePeculeContainer
    ) throws -> ModelContainer {
        // Une base en mémoire n'a ni fichier à perdre ni migration à craindre : ni copie, ni repère.
        guard !configuration.isStoredInMemoryOnly else { return try makeContainer(configuration) }

        let files = Files(storeURL: configuration.url)
        let version = currentVersion ?? Self.currentSchemaVersion
        var backup: URL?
        // Une base qui n'existe pas encore n'a rien à protéger : elle sera créée à la version courante.
        let storeExists = fileManager.fileExists(atPath: files.main.path)
        let versionRead = storedVersion(of: files)
        if storeExists {
            if versionRead != version {
                do { backup = try backUp(files, versionRead: versionRead) }
                catch {
                    let failure = StoreOpenError(stage: .backup, underlying: error, backup: nil)
                    AppLog.data.fault("Store backup failed (\(failure.identifier, privacy: .public)): \(String(describing: error), privacy: .private)")
                    throw failure
                }
            }
        }
        let container: ModelContainer
        do { container = try makeContainer(configuration) }
        catch {
            // Repère à jour : rien n'a été copié avant, or SwiftData a pu commencer à toucher la base. On la
            // copie maintenant, au mieux : l'erreur d'ouverture reste celle que l'utilisateur voit.
            if storeExists, backup == nil {
                do { backup = try backUp(files, versionRead: versionRead, afterFailedOpen: true) }
                catch {
                    let copyFailure = StoreOpenError(stage: .backup, underlying: error, backup: nil)
                    AppLog.data.error("Store backup after failed open failed (\(copyFailure.identifier, privacy: .public)): \(String(describing: error), privacy: .private)")
                }
            }
            let failure = StoreOpenError(stage: .open, underlying: error, backup: backup)
            AppLog.data.fault("Store open failed (\(failure.identifier, privacy: .public), backup kept: \(failure.hasBackup, privacy: .public)): \(String(describing: error), privacy: .private)")
            throw failure
        }
        // Seulement maintenant : un repère écrit trop tôt ferait passer une base mal ouverte pour migrée.
        // Un échec d'écriture ne doit pas empêcher d'utiliser des données qui viennent de s'ouvrir ; le
        // prochain lancement refera au pire une copie de plus.
        if storedVersion(of: files) != version {
            _ = fileManager.createFile(atPath: files.marker.path, contents: Data(version.utf8))
        }
        return container
    }

    // MARK: - Fichiers de la base

    struct Files {
        let directory: URL
        let name: String

        init(storeURL: URL) {
            directory = storeURL.deletingLastPathComponent()
            name = storeURL.lastPathComponent
        }

        // `.store`, puis le journal `-wal` (écritures validées non encore reportées) et `-shm` (son index).
        var names: [String] { [name, name + "-wal", name + "-shm"] }
        var main: URL { url(name) }
        var marker: URL { url(name + ".version") }
        // Propre à la base, donc au profil : chaque profil a son dossier, et le magasin historique le sien.
        var backups: URL { directory.appending(path: PersistentStoreOpener.backupsFolderName, directoryHint: .isDirectory) }

        func url(_ fileName: String) -> URL { directory.appending(path: fileName) }
    }

    private func storedVersion(of files: Files) -> String? {
        guard let data = fileManager.contents(atPath: files.marker.path),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Copies

    // Dossiers de copie de ce profil, du plus récent au plus ancien. Le nom commence par l'horodatage UTC à
    // largeur fixe : l'ordre alphabétique est l'ordre chronologique, et l'horloge injectée le rend testable.
    // Tout dossier qui n'a pas exactement ce nom est ignoré : on ne supprime que nos propres copies.
    func backupFolders(of files: Files) -> [URL] {
        backupFolderNames(in: files.backups).map { files.backups.appending(path: $0, directoryHint: .isDirectory) }
    }

    private func backUp(_ files: Files, versionRead: String?, afterFailedOpen: Bool = false) throws -> URL {
        let root = files.backups
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        excludeFromBackup(root)
        // Reliquats d'une copie interrompue : jamais valides, toujours à nous.
        for name in (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? [] where name.hasPrefix(Self.stagingPrefix) {
            try? fileManager.removeItem(at: root.appending(path: name))
        }

        // Un « Réessayer » après un échec d'ouverture revient ici avec le même repère. Si la base n'a pas
        // changé depuis la dernière copie, en refaire une ferait tourner les trois emplacements jusqu'à
        // chasser la copie d'origine : on la garde.
        let existing = backupFolderNames(in: root)
        if let latest = existing.first, matches(files, backup: root.appending(path: latest, directoryHint: .isDirectory)) {
            return root.appending(path: latest, directoryHint: .isDirectory)
        }

        let base = "\(Self.timestamp(now()))-\(Self.label(for: versionRead))" + (afterFailedOpen ? Self.failedOpenSuffix : "")
        var name = base
        var attempt = 1
        while fileManager.fileExists(atPath: root.appending(path: name).path) {
            attempt += 1
            name = "\(base)-\(attempt)"
        }
        let staging = root.appending(path: Self.stagingPrefix + name, directoryHint: .isDirectory)
        let destination = root.appending(path: name, directoryHint: .isDirectory)
        // La copie se fait dans un dossier provisoire, renommé seulement une fois complète : une copie
        // à moitié écrite (disque plein, arrêt brutal) ne prend jamais la place d'une bonne.
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
            excludeFromBackup(staging)
            for fileName in files.names where fileManager.fileExists(atPath: files.url(fileName).path) {
                try fileManager.copyItem(at: files.url(fileName), to: staging.appending(path: fileName))
            }
            try fileManager.moveItem(at: staging, to: destination)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
        excludeFromBackup(destination)

        // Après coup seulement, et jamais la copie qu'on vient de faire, même si une horloge déréglée
        // la fait paraître plus ancienne que les autres. Une copie issue d'un échec d'ouverture ne chasse pas
        // la dernière copie saine : celle-ci prend alors la place de la plus ancienne des copies gardées.
        let others = backupFolderNames(in: root).filter { $0 != name }
        var kept = Array(others.prefix(max(keptBackups - 1, 0)))
        if afterFailedOpen, !kept.contains(where: { !Self.isFailedOpenCopy($0) }),
           let healthy = others.first(where: { !Self.isFailedOpenCopy($0) }) {
            kept = Array(kept.dropLast()) + [healthy]
        }
        for stale in others where !kept.contains(stale) {
            try? fileManager.removeItem(at: root.appending(path: stale, directoryHint: .isDirectory))
        }
        return destination
    }

    // Le `-shm` n'est qu'un index reconstruit à partir du `-wal` : il peut changer à chaque ouverture sans
    // que les données aient bougé. Seuls la base et son journal comptent pour décider qu'elle n'a pas changé.
    private func matches(_ files: Files, backup: URL) -> Bool {
        for fileName in [files.name, files.name + "-wal"] {
            let live = files.url(fileName).path
            let copy = backup.appending(path: fileName).path
            let liveExists = fileManager.fileExists(atPath: live)
            guard liveExists == fileManager.fileExists(atPath: copy) else { return false }
            if liveExists, !fileManager.contentsEqual(atPath: live, andPath: copy) { return false }
        }
        return true
    }

    private func backupFolderNames(in root: URL) -> [String] {
        ((try? fileManager.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { Self.isBackupFolderName($0) && isDirectory(root.appending(path: $0)) }
            .sorted(by: >)
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    // Ces copies se refont à tout moment : elles n'ont rien à faire dans une sauvegarde iCloud ou iTunes,
    // où elles doubleraient le poids des données bancaires. Au mieux : un échec ne doit pas bloquer l'ouverture.
    private func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    // 20261005T123456Z, en UTC et sans deux-points.
    static func timestamp(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(
            dateSeparator: .omitted, dateTimeSeparator: .standard, timeSeparator: .omitted,
            timeZoneSeparator: .omitted, includingFractionalSeconds: false, timeZone: .gmt
        ))
    }

    // Le repère vient d'un fichier : il ne doit jamais pouvoir composer autre chose qu'un nom de dossier.
    static func label(for version: String?) -> String {
        guard let version, !version.isEmpty, version.count <= 32,
              version.allSatisfy({ $0.isASCII && ($0.isNumber || $0.isLetter || $0 == ".") }) else { return unknownVersionLabel }
        return version
    }

    static func isFailedOpenCopy(_ name: String) -> Bool {
        name.range(of: #"\.echec(-\d+)?$"#, options: .regularExpression) != nil
    }

    static func isBackupFolderName(_ name: String) -> Bool {
        name.range(of: #"^\d{8}T\d{6}Z-[0-9A-Za-z.]+(-\d+)?$"#, options: .regularExpression) != nil
    }
}

// A reload that could not read the store: the same short, personal-data-free identifier as StoreOpenError,
// for the same recovery screen.
struct DataLoadFailure: Equatable, Sendable {
    let identifier: String

    init(_ error: Error) {
        let nsError = error as NSError
        identifier = "load-\(nsError.domain)-\(nsError.code)"
    }
}
